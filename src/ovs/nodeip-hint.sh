#!/bin/bash
# OpenShift's nodeip-configuration tells configure-ovs which interface holds
# the node IP. Without that hint configure-ovs takes the default-route
# interface only, so a node on a network with no default route (isolated,
# air-gapped) gets no br-ex. This writes MicroShift's own node IP choice
# (node.nodeIP, else the default route's, else the first host address): br-ex
# then always holds the node IP MicroShift uses.
set -euo pipefail
ip="$(microshift show-config -m effective |
    awk '/^node:/ {n = 1; next} /^[^ ]/ {n = 0} n && $1 == "nodeIP:" {gsub(/"/, "", $2); print $2; exit}')"
[ -n "${ip}" ] || { echo "no node IP in microshift show-config" >&2; exit 1; }
mkdir -p /run/nodeip-configuration
echo "${ip}" > /run/nodeip-configuration/primary-ip
echo "node IP hint for configure-ovs: ${ip}"
