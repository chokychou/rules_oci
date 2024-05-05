#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

# Add hermetically built jq, regctl, coreutils into PATH.
PATH="{{jq_path}}:$PATH"
PATH="{{regctl_path}}:$PATH"
PATH="{{coreutils_path}}:$PATH"
PATH="{{zstd_path}}:$PATH"

# Constants
readonly OUTPUT="{{output}}"
readonly REF="ocidir://$OUTPUT:intermediate"
# shellcheck disable=SC2016
readonly ENV_EXPAND_FILTER='[$raw | match("\\${?([a-zA-Z0-9_]+)}?"; "gm")] | reduce .[] as $match (
    {parts: [], prev: 0}; 
    {parts: (.parts + [$raw[.prev:$match.offset], ($envs[] | select(.key == $match.captures[0].string)).value ]), prev: ($match.offset + $match.length)}
) | .parts + [$raw[.prev:]] | join("")'

function base_from_scratch() {
  local platform="$1"
  local config_digest=
  # Create the image config
  config_digest=$(jq -n --argjson platform "$platform" '{config:{}, rootfs:{type: "layers", diff_ids:[]}} + $platform' | regctl blob put $REF)
  # Create a new manifest
  jq -n --arg digest "$config_digest" '{
    schemaVersion: 2, 
    mediaType: "application/vnd.oci.image.manifest.v1+json", 
    config: { mediaType: "application/vnd.oci.image.config.v1+json", digest: $digest },
    layers: []
  }' | regctl manifest put $REF
}

function base_from() {
  local path="$1"
  # shellcheck disable=SC2045
  for blob in $(ls -1 -d "$path/blobs/"*/*); do
    local relative=${blob#"$path/"}
    mkdir -p "$OUTPUT/$(dirname "$relative")"
    cat "$blob" >"$OUTPUT/$relative"
  done
  cat "$path/oci-layout" >"$OUTPUT/oci-layout"
  jq '.manifests[0].annotations["org.opencontainers.image.ref.name"] = "intermediate"' "$path/index.json" >"$OUTPUT/index.json"
}

function get_config() {
  regctl blob get "$REF" "$(regctl manifest get "$REF" --format "{{.Config.Digest}}")"
}

function update_config() {
  local digest=
  digest=$(cat - | regctl blob put $REF)
  regctl manifest get $REF --format "raw" | jq '.config.digest = $digest' --arg digest "$digest" | regctl manifest put $REF >/dev/null
  echo "$digest"
}

function get_manifest() {
  regctl manifest get "$REF" --format "raw"
}

function update_manifest() {
  regctl manifest put "$REF"
}

function add_layer() {
  local path=
  # https://github.com/opencontainers/image-spec/blob/main/media-types.md
  local media_type="application/vnd.oci.image.layer.v1.tar"
  local digest=
  local diffid=
  local size=
  # TODO: might not be necessary.
  path=$(realpath "$1")
  digest=$(regctl digest <"$path")
  diffid="$digest"
  size=$(wc -c "$path" | awk '{print $1}')

  if [[ $(coreutils od -An -t x1 --read-bytes 2 "$path") == " 1f 8b" ]]; then
    media_type="$media_type+gzip"
    diffid=$(zstd -f -q --decompress --format=gzip <"$path" | regctl digest)
  elif zstd -t "$path" 2>/dev/null; then
    media_type="$media_type+zstd"
    diffid=$(zstd --decompress --format=zstd <"$path" | regctl digest)
  fi

  # echo "$media_type $diffid $digest"

  new_config_digest=$(get_config | jq --arg diffid "$diffid" '.rootfs.diff_ids += [$diffid]' | update_config)

  get_manifest |
    jq '.config.digest = $config_digest | .layers += [{size: $size, digest: $layer_digest, mediaType: $media_type}]' \
      --arg config_digest "$new_config_digest" \
      --arg layer_digest "$digest" \
      --arg media_type "$media_type" \
      --argjson size "$size" | update_manifest

  regctl blob put "$REF" <"$path" >/dev/null
}

CONFIG="{}"

for ARG in "$@"; do
  case "$ARG" in
  --scratch=*)
    base_from_scratch "${ARG#--scratch=}"
    ;;
  --from=*)
    base_from "${ARG#--from=}"
    ;;
  --layer=*) add_layer "${ARG#--layer=}" ;;
  --env=*)
    # Get environment from existing config
    env=$(get_config | jq '(.config.Env // []) | map(. | split("=") | {"key": .[0], "value": .[1:] | join("=")})')

    while IFS= read -r expansion || [ -n "$expansion" ]; do
      IFS="=" read -r key value <<<"${expansion}"
      value_from_base=$(jq -nr --arg raw "${value}" --argjson envs "${env}" "${ENV_EXPAND_FILTER}")
      env=$(
        # update the existing env if it exists, or append to the end of env array.
        jq -r --arg key "$key" --arg value "$value_from_base" '. |= (map(.key) | index($key)) as $i | if $i then .[$i]["value"] = $value else . + [{key: $key, value: $value}] end' <<<"$env"
      )
    done <"${ARG#--env=}"

    CONFIG=$(jq --argjson envs "${env}" '.config.Env = ($envs | map("\(.key)=\(.value)"))' <<<"$CONFIG")
    ;;
  --cmd=*)
    CONFIG=$(jq --rawfile cmd "${ARG#--cmd=}" '.config.Cmd = ($cmd | split(",|\n"; "") | map(select(. | length > 0)))' <<<"$CONFIG")
    ;;
  --entrypoint=*)
    CONFIG=$(jq --rawfile entrypoint "${ARG#--entrypoint=}" '.config.Entrypoint = ($entrypoint | split(",|\n"; "") | map(select(. | length > 0)))' <<<"$CONFIG")
    ;;
  --exposed-ports=*)
    CONFIG=$(jq --rawfile ep "${ARG#--exposed-ports=}" '.config.ExposedPorts = ($ep | split(",") | map({key: ., value: {}}) | from_entries)' <<<"$CONFIG")
    ;;
  --user=*)
    CONFIG=$(jq --arg user "${ARG#--user=}" '.config.User = $user' <<<"$CONFIG")
    ;;
  --workdir=*)
    CONFIG=$(jq --arg workdir "${ARG#--workdir=}" '.config.WorkingDir = $workdir' <<<"$CONFIG")
    ;;
  --labels=*)
    CONFIG=$(jq --rawfile labels "${ARG#--labels=}" '.config.Labels += ($labels | split("\n") | map(. | split("=")) | map({key: .[0], value: .[1:] | join("=")}) | from_entries)' <<<"$CONFIG")
    ;;
  --annotations=*)
    get_manifest |
      jq --rawfile annotations "${ARG#--annotations=}" \
        '.annotations += ($annotations | split("\n") | map(. | split("=")) | map({key: .[0], value: .[1:] | join("=")}) | from_entries)' |
      update_manifest
    ;;
  *)
    echo "unknown argument ${ARG}"
    exit 1
    ;;
  esac
done

get_config | jq --argjson config "$CONFIG" '. += $config' | update_config >/dev/null
