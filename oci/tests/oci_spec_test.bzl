""

load("@bazel_skylib//rules:native_binary.bzl", "native_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

DIGEST_CMD = """
image_path="$(location {image})"
manifest_digest=$$($(JQ_BIN) -r '.manifests[0].digest | sub(":"; "/")' $$image_path/index.json)
config_digest=$$($(JQ_BIN) -r '.config.digest | sub(":"; "/")' $$image_path/blobs/$$manifest_digest)

$(JQ_BIN) 'def pick(p): . as $$v | reduce path(p) as $$p ({{}}; setpath($$p; $$v | getpath($$p))); pick({keys})' "$$image_path/blobs/$$config_digest" > $@
"""

def oci_spec_config_assert(
        name,
        image,
        entrypoint_eq = None,
        cmd_eq = None,
        env_eq = None,
        ports_eq = None,
        user_eq = None,
        workdir_eq = None,
        architecture_eq = None,
        os_eq = None,
        variant_eq = None,
        labels = None):
    pick = []

    config = {}

    # .config
    if entrypoint_eq:
        config["Entrypoint"] = entrypoint_eq
    if cmd_eq:
        config["Cmd"] = cmd_eq
    if env_eq:
        config = ["=".join(e) for e in env_eq.items()]

    pick = [".config." + k for k in config.keys()]

    # .
    config_json = {}

    if os_eq:
        config_json["os"] = os_eq
    if architecture_eq:
        config_json["architecture"] = architecture_eq
    if variant_eq:
        config_json["variant"] = variant_eq

    pick += ["." + k for k in config_json.keys()]

    if len(config.keys()):
        config_json["config"] = config

    expected = name + "_json"
    write_file(
        name = expected,
        out = name + ".json",
        content = [
            json.encode(config_json),
        ],
    )

    actual = name + "_config_json"
    native.genrule(
        name = actual,
        srcs = [image],
        outs = [name + ".config.json"],
        cmd = DIGEST_CMD.format(keys = ",".join(pick), image = image),
        toolchains = ["@jq_toolchains//:resolved_toolchain"],
    )

    native_test(
        name = name,
        data = [
            expected,
            actual,
        ],
        args = [
            "$(location %s)" % expected,
            "$(location %s)" % actual,
        ],
        src = select({
            "//oci/tests:darwin_arm64": "@jd_darwin_arm64//file",
            "//oci/tests:linux_amd64": "@jd_linux_amd64//file",
        }),
        out = name,
    )
