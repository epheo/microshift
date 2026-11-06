#!/bin/bash
# Vendor r-drbd's deploy/base at R_DRBD_COMMIT (versions.env) into
# src/r-drbd/base, verbatim, and list every image it deploys in
# src/r-drbd/release-r-drbd-x86_64.json, which the bootc stage installs next
# to MicroShift's release-info so the payload embed carries them too.
# Rerun after bumping R_DRBD_COMMIT and commit the result.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source versions.env

base=src/r-drbd/base
files="kustomization.yaml crds.yaml 00-namespace-rbac.yaml 10-csidriver.yaml 20-controller.yaml 30-agent.yaml 40-storageclasses.yaml"
rm -rf "${base}"
mkdir -p "${base}"
for f in ${files}; do
    curl -fsSL --retry 3 -o "${base}/${f}" \
        "https://raw.githubusercontent.com/epheo/r-drbd/${R_DRBD_COMMIT}/deploy/base/${f}"
done

# Every image the rendered manifests run, keyed by its name.
oc kustomize "${base}" \
    | yq -o=json -I=0 '[.. | select(has("image")) | .image] | .[]' 2>/dev/null \
    | jq -rs 'unique | map({(split("/")[-1] | split(":")[0] | split("@")[0]): .}) | add | {images: .}' \
    > src/r-drbd/release-r-drbd-x86_64.json
cat src/r-drbd/release-r-drbd-x86_64.json
