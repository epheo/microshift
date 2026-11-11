#!/bin/bash
# Pull each image into root's podman store, with retries: registry CDNs
# flake (unexpected EOF mid-blob), and every later step builds or boots from
# the local store.
set -euo pipefail

for img in "$@"; do
    for i in $(seq 5); do
        if sudo podman pull -q "${img}"; then break; fi
        if [ "${i}" = 5 ]; then echo "ERROR: could not pull ${img}" >&2; exit 1; fi
        echo "pull failed (attempt ${i}) for ${img}, retrying"
        sleep 15
    done
done
