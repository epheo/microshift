#!/bin/bash
# Build-time (bootc stage): embed every image MicroShift deploys — the refs
# in the installed release-info JSONs — into one shared-blob OCI layout under
# /usr/lib/embedded-images, and list them in the import manifest. Deriving
# the list from the JSONs means a payload bump cannot silently reintroduce a
# first-boot registry pull.
#
# Digest-pinned refs must survive byte-exact (--preserve-digests): pods
# reference them by digest and the boot import refuses a mismatch. That is
# only possible because prebuild.sh pins per-arch instance digests; a
# manifest-list digest cannot be stored unmodified in an OCI layout, so a
# regression there is caught here at build, not on the node.
set -euo pipefail

ARCH="$(uname -m)"
RELEASE_DIR=/usr/share/microshift/release
DEST_DIR=/usr/lib/embedded-images
LAYOUT="${DEST_DIR}/payload"
MANIFEST="${DEST_DIR}/manifest"

mkdir -p "${DEST_DIR}"

jq -r '.images | to_entries[] | "\(.key) \(.value)"' \
        "${RELEASE_DIR}"/release-*"${ARCH}".json \
| while read -r key ref; do
    # Not deployed by this distribution: TopoLVM replaces LVMS (and the LVMS
    # ref needs registry.redhat.io auth).
    if [ "${key}" = "lvms_operator" ]; then
        continue
    fi
    echo "embedding ${key} (${ref})"
    # quay's CDN flakes with unexpected EOF mid-blob under load; retries are
    # whole-copy, so give it headroom and a pause between attempts.
    skopeo copy -q --retry-times 5 --retry-delay 10s --preserve-digests \
        "docker://${ref}" "oci:${LAYOUT}:${key}"
    case "${ref}" in
    *@sha256:*)
        stored="sha256:$(skopeo inspect --raw "oci:${LAYOUT}:${key}" | sha256sum | cut -d' ' -f1)"
        if [ "${stored}" != "${ref##*@}" ]; then
            echo "ERROR: ${key}: embedded digest ${stored} does not match" \
                 "pinned ${ref##*@}; prebuild.sh must pin instance digests" >&2
            exit 1
        fi
        ;;
    esac
    echo "oci:${LAYOUT}:${key} ${ref}" >> "${MANIFEST}"
done

echo "embedded payload size: $(du -sh "${LAYOUT}" | cut -f1)"
