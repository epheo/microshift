#!/bin/bash
# Failure-diagnostics helpers shared by vm-test.sh and multinode-test.sh, which
# must not drift apart: the multinode lane is the only reproducer of cross-node
# bugs, and a dedup or unit-list fix applied to one script used to be invisible
# in the other. Each caller passes its own remote-exec function (vssh, v1, v2).
# multinode-smoke.sh diverges on purpose (containers: no boots to filter on, no
# NetworkManager, no bootc, no SELinux) and does not source this file.

# OVS runs outside MicroShift, which only validates br-ex and exits, so an OVS
# failure reads as a bare "microshift.service did not become active" with no
# cause in the microshift journal.
DIAG_OVS_UNITS="openvswitch ovsdb-server ovs-vswitchd microshift-ovs-init NetworkManager"

diag_ovs_journals() { # diag_ovs_journals <exec-fn> [label]
    local fn=$1 label=${2:+$2: } u
    for u in ${DIAG_OVS_UNITS}; do
        echo "### ${label}journalctl -u ${u} (this boot) ###"
        ${fn} journalctl -u "${u}" --no-pager -b 2>&1
    done
}

# A bootc switch can leave the booted SELinux policy unable to resolve a label
# the image's /usr carries, which denies ovs-ctl and takes OVS down the same
# way: tcontext=unlabeled_t with a valid trawcon= in the AVC is that signature.
# One retry loop trips the same denial hundreds of times, so collapse them: the
# histogram, not the flood, names the offending label.
diag_selinux() { # diag_selinux <exec-fn> <top-n> [label]
    local fn=$1 top=$2 label=${3:+$3: }
    echo "### ${label}selinux modules (microshift, ovs) ###"
    ${fn} sh -c 'semodule -l | grep -iE "microshift|openvswitch|ovs"' 2>&1
    echo "### ${label}selinux denials this boot (deduped, top ${top}) ###"
    ${fn} sh -c "journalctl -b --no-pager --grep='avc: *denied' \
        | sed -E 's/^.*avc: /avc: /; s/pid=[0-9]+ //; s/ino=[0-9]+ //' \
        | sort | uniq -c | sort -rn | head -${top}" 2>&1
}
