#!/bin/bash
# Import the boot-critical container images shipped in the bootc image
# (/usr/lib/embedded-images — the distro embeds portail; site layers may add more archives + manifest lines) into cri-o's
# graphroot. Runs before MicroShift on every boot and is idempotent, so a
# cold boot — even with a wiped /var image cache — needs no registry.
#
# Why not additionalimagestores: this cri-o build lists additional-store
# images (ListImages) but ImageStatus — the call kubelet makes for
# IfNotPresent — does not resolve them, so pods try to pull anyway.
set -euo pipefail

MANIFEST=/usr/lib/embedded-images/manifest
STORE="containers-storage:[overlay@/var/lib/containers/storage+/run/containers/storage]"

[ -f "${MANIFEST}" ] || { echo "no embedded image manifest, nothing to do"; exit 0; }

while read -r tar name; do
    [ -n "${name}" ] || continue
    if skopeo inspect --no-tags "${STORE}${name}" >/dev/null 2>&1; then
        echo "${name}: already present"
        continue
    fi
    echo "importing ${name} from ${tar}"
    skopeo copy "oci-archive:${tar}" "${STORE}${name}"
done < "${MANIFEST}"
