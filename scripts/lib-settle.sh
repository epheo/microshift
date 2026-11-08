#!/bin/bash
# Settle checks shared by vm-test.sh and multinode-test.sh: the multinode lane
# once missed a fix made in vm-test. Each caller defines koc.

# Graceful node shutdown (for r-drbd) leaves the pods it killed Failed with
# reason Terminated, shown as Error, until pod GC: only their replacements
# tell whether the new boot settled. A bare pod has none and stays dead.
unsettled_pods() {
    local killed
    killed="$(koc get pods -A -o jsonpath='{range .items[?(@.status.reason=="Terminated")]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)" || true
    koc get pods -A --no-headers 2>/dev/null \
        | awk -v killed=" ${killed}" '!/Running|Completed/ && index(killed, " " $1 "/" $2 " ") == 0'
}
