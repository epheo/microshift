#!/bin/bash
# Drop localhost/embedded/* tags that no deployment on disk ships and no
# workload references. The boot import only adds, so every base update left
# its embedded tags in cri-o's store for good.
#
# Kept:
# - what the booted, rollback and staged deployments ship: bootc rollback
#   and the update in waiting find their images in place;
# - every image a pod or workload template names: a site's manifests can
#   lag its node by more than one update, and an embedded tag cannot be
#   pulled back.
# Old ReplicaSets are not read: their templates would pin every tag of the
# last ten rollouts.
#
# Anything it cannot read stops it before it removes anything.
set -euo pipefail

PREFIX=localhost/embedded/
MANIFEST=/usr/lib/embedded-images/manifest
export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig

keep="$(mktemp)"
trap 'rm -f "${keep}"' EXIT

status="$(bootc status --json)"
for slot in booted rollback staged; do
    commit="$(jq -r ".status.${slot}.ostree.checksum // empty" <<<"${status}")"
    [ -n "${commit}" ] || continue
    ostree cat --repo=/sysroot/ostree/repo "${commit}" "${MANIFEST}" | awk '{print $2}' >> "${keep}"
done
# bootc reporting no booted deployment would mean an empty keep list.
grep -qF "${PREFIX}" "${keep}" || { echo "no shipped embedded image found, nothing removed"; exit 1; }

oc get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json --request-timeout=60s \
    | jq -r '.items[]
        | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // .spec)
        | ((.containers // []) + (.initContainers // []) + (.ephemeralContainers // []))[]
        | .image' >> "${keep}"

crictl images -o json | jq -r --arg p "${PREFIX}" '.images[].repoTags[]? | select(startswith($p))' | sort -u \
    | while read -r name; do
        grep -qxF "${name}" "${keep}" && continue
        echo "removing ${name}"
        crictl rmi "${name}" >/dev/null
    done
