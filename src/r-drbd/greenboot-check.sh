#!/bin/bash
# Required greenboot check for the r-drbd storage plane.
set -euo pipefail

# shellcheck disable=SC1091
source /usr/share/microshift/functions/greenboot.sh

SCRIPT_NAME=$(basename "$0")

if [ "$(id -u)" -ne 0 ] ; then
    echo "The '${SCRIPT_NAME}' script must be run with the 'root' user privileges"
    exit 1
fi

exit_if_fail_marker_exists

# Workers cannot query cluster workloads; the controller's check gates them.
if [ -f /var/lib/microshift/multinode-worker ]; then
    echo "SKIPPED (worker node)"
    exit 0
fi

echo "STARTED"

WAIT_TIMEOUT_SECS=$(get_wait_timeout)

if ! microshift healthcheck \
        -v=2 --timeout="${WAIT_TIMEOUT_SECS}s" \
        --custom '{"r-drbd-system":{"deployments": ["r-drbd-controller"], "daemonsets": ["r-drbd-agent"]}}'; then
    create_fail_marker_and_exit
fi
