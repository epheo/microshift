# shellcheck shell=bash disable=SC2154 # callers set release, refs and sources
# Sourced by the vendor scripts. Each takes a file from the source commit the
# pinned OKD payload (versions.env) was built from, so it moves with every
# payload bump. Callers set release, refs and sources.

# payload_refs: the payload's image-references, which names each component's
# source repository and commit, into ${refs}. With oc when present, else with
# podman from the release image (CI has no oc); both give the same file.
payload_refs() {
    if command -v oc >/dev/null; then
        oc adm release extract --file=image-references "${release}" > "${refs}"
    else
        local ctr
        ctr="$(podman create -q "${release}")"
        podman cp "${ctr}:/release-manifests/image-references" - | tar -xO > "${refs}"
        podman rm -f "${ctr}" >/dev/null
    fi
}

# fetch <component> <path>: the file at the commit the payload built it from.
# Records "repo path @ commit" in ${sources} for the generated file's header.
fetch() {
    local repo commit
    read -r repo commit < <(jq -r --arg n "$1" '.spec.tags[] | select(.name == $n) | .annotations |
        "\(.["io.openshift.build.source-location"] // "") \(.["io.openshift.build.commit.id"] // "")"' "${refs}")
    if [ -z "${repo}" ] || [ -z "${commit}" ]; then
        echo "no source or commit for $1 in ${release}" >&2
        return 1
    fi
    echo "${repo#https://} ${2} @ ${commit}" >> "${sources}"
    curl -fsSL --retry 3 "${repo/github.com/raw.githubusercontent.com}/${commit}/$2"
}
