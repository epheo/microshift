#!/bin/bash
# Pin the pinned OKD payload's (versions.env) full container-networking-plugins
# image into src/cni/plugins-image. The bootc build copies host-device from
# it: MicroShift's own plugins image has bridge, dhcp, host-local, ipvlan,
# macvlan and static only. scripts/bump-versions.sh reruns it; the build job
# fails when the committed pin differs from what the payload names.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source versions.env

release="${OKD_RELEASE_IMAGE}:${OKD_VERSION_TAG}"
refs="$(mktemp)"
trap 'rm -f "${refs}"' EXIT

# shellcheck source=src/lib/payload-source.sh
source src/lib/payload-source.sh
payload_refs

jq -er '.spec.tags[] | select(.name == "container-networking-plugins") | .from.name' "${refs}" \
    > src/cni/plugins-image
echo "pinned $(cat src/cni/plugins-image) from ${release}"
