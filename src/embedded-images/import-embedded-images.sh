#!/bin/bash
# Import the container images shipped in the bootc image under
# /usr/lib/embedded-images into cri-o's graphroot: the full MicroShift
# payload (shared-blob OCI layout, see embed-release-images.sh), portail,
# and whatever archives site layers add manifest lines for. Runs before
# MicroShift on every boot and is idempotent, so a cold boot — even
# air-gapped, even with a wiped /var image cache — needs no registry.
#
# Why not additionalimagestores: this cri-o build lists additional-store
# images (ListImages) but ImageStatus — the call kubelet makes for
# IfNotPresent — does not resolve them, so pods try to pull anyway.
set -euo pipefail

MANIFEST=/usr/lib/embedded-images/manifest
STORE="containers-storage:[overlay@/var/lib/containers/storage+/run/containers/storage]"

[ -f "${MANIFEST}" ] || { echo "no embedded image manifest, nothing to do"; exit 0; }

while read -r src name; do
    [ -n "${name}" ] || continue
    # Site layers list bare tar paths; the distro payload lists oci: refs.
    case "${src}" in
        /*) src="oci-archive:${src}" ;;
    esac
    if skopeo inspect --no-tags "${STORE}${name}" >/dev/null 2>&1; then
        echo "${name}: already present"
        continue
    fi
    echo "importing ${name} from ${src}"
    skopeo copy -q "${src}" "${STORE}${name}"
done < "${MANIFEST}"
