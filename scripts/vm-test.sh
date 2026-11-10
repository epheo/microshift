#!/bin/bash
# The canonical acceptance test: turn the bootc image into a qcow2 disk with
# bootc-image-builder, boot it as a real VM under QEMU/KVM, and assert the
# distribution's opinions on a genuine boot — bootloader, ostree deployment,
# systemd boot order, and greenboot actually gating the boot. This is what
# `make smoke` (privileged container, fast local iteration) cannot validate.
# The opinion assertions are functional, not existence checks: a PVC is
# provisioned and written, an OVN-K layer2 secondary network is attached,
# a MultiNetworkPolicy cuts a pod off that network and its removal restores
# it, an AdminNetworkPolicy does the same on the cluster network, an
# EgressFirewall cuts one namespace off a node address, the
# embedded portail image is started with pull policy Never, the API
# accepts TCPRoute and UDPRoute objects, and RBAC answers as OpenShift's
# does for signed-in users and the stock project roles (src/rbac).
# The fresh-install VM runs with zero egress (restrict=on): going GREEN
# proves the air-gapped first boot the embedded payload exists for.
#
# With UPGRADE_FROM set, the same suite runs on an upgraded system instead
# of a fresh install: boot a qcow2 built from the previously published
# image, bootc switch to the freshly built candidate (served from a
# throwaway local registry over the QEMU user network), reboot, then
# assert. This is the path every existing install takes on a publish;
# switch to a local ref stands in for the bootc upgrade users run, because
# the candidate is by definition not on ghcr yet. A missing UPGRADE_FROM
# fails the run; set UPGRADE_ALLOW_MISSING=1 to skip instead (first
# release, forks).
#
# With ROLLBACK=1 as well, the candidate first goes red on purpose: greenboot
# must roll it back and MicroShift must restore the previous release's data
# (an older binary refuses data a newer minor migrated). Then the candidate
# is installed again and the suite runs on it as usual.
#
# Requires root-capable podman (bootc-image-builder is a privileged container
# reading the root containers-storage) and qemu-system-x86_64. Uses KVM when
# /dev/kvm exists, falls back to TCG (slow) otherwise. Upgrade mode also
# needs jq on the host.
#
# Usage: DIST_IMAGE=epheo-microshift ./scripts/vm-test.sh
#        UPGRADE_FROM=ghcr.io/epheo/microshift:latest ./scripts/vm-test.sh
set -euo pipefail

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
UPGRADE_FROM="${UPGRADE_FROM:-}"
UPGRADE_ALLOW_MISSING="${UPGRADE_ALLOW_MISSING:-}"
ROLLBACK="${ROLLBACK:-}"
USHIFT_GITREF="${USHIFT_GITREF:-$(sed -n 's/^USHIFT_GITREF=//p' "$(dirname "$0")/../versions.env")}"
. "$(dirname "$0")/lib-diag.sh"
. "$(dirname "$0")/lib-settle.sh"
WORKDIR="${WORKDIR:-/tmp/epheo-microshift-vm${UPGRADE_FROM:+-upgrade}}"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEM="${VM_MEM:-8192}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-quay.io/libpod/registry:2.8}"
REG_PORT="${REG_PORT:-5000}"
REG_NAME=epheo-microshift-upgrade-registry
# 10.0.2.2 is the QEMU user-network alias for the host loopback.
CANDIDATE_REF="10.0.2.2:${REG_PORT}/epheo-microshift:candidate"
VG_NAME="myvg1" # the VG microshift-r-drbd-default-pool turns into a Pool
FORCE_RED_CHECK=/etc/greenboot/check/required.d/99_vm_test_force_red.sh
FORCE_RED_TRIGGER=/var/vm-test-force-red

log() { echo "--- $*"; }

QEMU_PID=""
cleanup() {
    rc=$?
    # Collect in-VM state while the guest is still reachable, before killing it.
    if [ ${rc} -ne 0 ]; then
        log "FAILED (rc=${rc}); collecting diagnostics"
        dump_diag || true
    fi
    [ -n "${QEMU_PID}" ] && sudo kill "${QEMU_PID}" 2>/dev/null || true
    [ -n "${UPGRADE_FROM}" ] && sudo podman rm -f "${REG_NAME}" 2>/dev/null || true
    if [ ${rc} -ne 0 ]; then
        log "last 60 lines of VM console:"
        sudo tail -60 "${WORKDIR}/console.log" 2>/dev/null || true
    fi
    exit ${rc}
}
trap cleanup EXIT

# ssh adds a remote shell evaluation layer that strips quoting from args
# (e.g. the backslash in a kubectl jsonpath) — re-quote every arg with
# printf %q so commands run remotely exactly as written here.
vssh() {
    ssh -p "${SSH_PORT}" -i "${WORKDIR}/id" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR \
        root@127.0.0.1 "$(printf '%q ' "$@")"
}

KCFG=/var/lib/microshift/resources/kubeadmin/kubeconfig
koc() { vssh oc --kubeconfig "${KCFG}" "$@"; }

# A NotReady node, or a microshift.service that never comes up, is usually an
# OVS/OVN-K, crio or SELinux failure, none of which reach the serial console
# (they log to journald). Write the full state to a file the workflow uploads
# as an artifact, and tail it to the job log for quick triage.
# All best-effort: the guest may be half-up, so nothing here may fail cleanup.
dump_diag() {
    local ns=openshift-ovn-kubernetes
    local out="${WORKDIR}/diag.log"
    {
        echo "### journalctl -u microshift (this boot) ###"
        vssh journalctl -u microshift --no-pager -b 2>&1
        echo "### journalctl -u crio (this boot) ###"
        vssh journalctl -u crio --no-pager -b 2>&1
        echo "### nodes ###"; koc get nodes -o wide 2>&1
        echo "### pods -A ###"; koc get pods -A -o wide 2>&1
        echo "### ${ns} describe ###"; koc -n "${ns}" describe pods 2>&1
        echo "### ${ns} logs ###"
        for p in $(koc -n "${ns}" get pods -o name 2>/dev/null); do
            echo "--- ${p} ---"
            koc -n "${ns}" logs "${p}" --all-containers --prefix --tail=300 2>&1
        done
        diag_ovs_journals vssh

        # Everything below stays short, and the highest-signal sections come
        # last: the tail printed to the job log has to name the cause without
        # anyone opening the artifact.
        echo "### bootc status ###"; vssh bootc status 2>&1
        echo "### ovs-vsctl show ###"; vssh ovs-vsctl --timeout=5 show 2>&1
        echo "### ip -br addr ###"; vssh ip -br addr 2>&1
        echo "### failed units ###"
        vssh systemctl list-units --failed --no-pager 2>&1
        # Bounded repeat of crio's errors: the full crio journal above sits
        # under five uncapped unit journals, far out of the tail's reach, and
        # crio-only failures (the policy.json pull break) must still show in
        # the job log.
        echo "### crio errors (this boot, last 40) ###"
        vssh sh -c 'journalctl -u crio --no-pager -b | grep -E "level=(error|fatal)" | tail -40' 2>&1
        diag_selinux vssh 30
    } > "${out}" 2>&1 || true
    log "diagnostics written to ${out} (uploaded as an artifact); tail:"
    tail -n 200 "${out}" 2>/dev/null || true
}

# wait_for SECONDS WHAT CMD...: run CMD every 5s until it succeeds.
wait_for() {
    local secs=$1 what=$2
    shift 2
    log "waiting for ${what} (up to $((secs / 60))m)"
    for _ in $(seq $((secs / 5))); do
        "$@" 2>/dev/null && return 0
        sleep 5
    done
    echo "ERROR: no ${what} after $((secs / 60))m" >&2
    return 1
}

node_ready() { koc get node | grep -q ' Ready '; }
wait_microshift() {
    wait_for 300 "active microshift.service" vssh systemctl is-active -q microshift.service
    wait_for 300 "Ready node" node_ready
}

# Precise: after a greenboot rollback the candidate ref still appears in the
# deployment list, so a substring grep over the whole status passes wrongly.
booted_image() { vssh bootc status --json | jq -r '.status.booted.image.image.image'; }

# The log phrasing differs between greenboot implementations (bash: "Boot
# Status is GREEN"; the CS10 Rust rewrite: "greenboot health-check passed").
# -b: with a persistent journal a pre-upgrade GREEN would satisfy the grep.
greenboot_green() {
    vssh journalctl -b -u greenboot-healthcheck --no-pager \
        | grep -qiE 'Status is GREEN|health-check passed'
}

# wait_pod_running POD [NAMESPACE]
wait_pod_running() {
    local pod=$1 ns=${2:-default} phase=""
    for _ in $(seq 60); do
        phase="$(koc -n "${ns}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [ "${phase}" = "Running" ] && return 0
        sleep 5
    done
    echo "ERROR: pod ${ns}/${pod} never became Running (phase=${phase})" >&2
    koc -n "${ns}" describe pod "${pod}" >&2 || true
    return 1
}

# --- 1. Prepare the workdir, ssh key and builder config ----------------------
sudo rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/output"
ssh-keygen -q -t ed25519 -N '' -f "${WORKDIR}/id"
cat > "${WORKDIR}/config.toml" <<EOF
[[customizations.user]]
name = "root"
key = "$(cat "${WORKDIR}/id.pub")"
EOF

if [ -n "${UPGRADE_FROM}" ]; then
cat >> "${WORKDIR}/config.toml" <<EOF

# Upgrade mode only: let bootc switch pull the candidate from the host over
# plain HTTP, and leave headroom for a second full deployment in the ostree
# repo plus the runtime image cache.
[[customizations.files]]
path = "/etc/containers/registries.conf.d/900-upgrade-test.conf"
data = "[[registry]]\nlocation = \"10.0.2.2:${REG_PORT}\"\ninsecure = true\n"

[[customizations.filesystem]]
mountpoint = "/"
minsize = "20 GiB"
EOF
fi

# --- 2. Make the image available to rootful podman ---------------------------
if podman image exists "${DIST_IMAGE}" 2>/dev/null; then
    rootless_id="$(podman image inspect --format '{{.Id}}' "${DIST_IMAGE}")"
    rootful_id="$(sudo podman image inspect --format '{{.Id}}' "${DIST_IMAGE}" 2>/dev/null || true)"
    if [ "${rootless_id}" != "${rootful_id}" ]; then
        log "copying ${DIST_IMAGE} from the user image store to the root store"
        podman save "${DIST_IMAGE}" | sudo podman load
    fi
elif ! sudo podman image exists "${DIST_IMAGE}"; then
    echo "ERROR: image '${DIST_IMAGE}' not found (run 'make image' first)" >&2
    exit 1
fi

# --- 2b. Upgrade mode: fetch the previous release, serve the candidate -------
SRC_IMAGE="localhost/${DIST_IMAGE}:latest"
if [ -n "${UPGRADE_FROM}" ]; then
    log "pulling the previous release ${UPGRADE_FROM}"
    pull_err="${WORKDIR}/pull-err.txt"
    if ! sudo podman pull -q "${UPGRADE_FROM}" 2> "${pull_err}"; then
        cat "${pull_err}" >&2
        # ghcr answers denied for a missing package too, which an outage or an
        # auth regression also produces: skipping is opt-in, or a broken
        # registry would silently drop the upgrade gate and still publish.
        if [ -n "${UPGRADE_ALLOW_MISSING}" ] && \
                grep -qiE 'manifest unknown|name unknown|not found|denied' "${pull_err}"; then
            log "SKIPPED: nothing published at ${UPGRADE_FROM} to upgrade from"
            exit 0
        fi
        echo "ERROR: could not pull ${UPGRADE_FROM}" >&2
        exit 1
    fi
    SRC_IMAGE="${UPGRADE_FROM}"

    log "serving the candidate at ${CANDIDATE_REF} for bootc switch"
    sudo podman rm -f "${REG_NAME}" 2>/dev/null || true
    sudo podman run -d --name "${REG_NAME}" \
        -p "127.0.0.1:${REG_PORT}:5000" "${REGISTRY_IMAGE}" >/dev/null
    sudo podman tag "${DIST_IMAGE}" "localhost:${REG_PORT}/epheo-microshift:candidate"
    for i in $(seq 5); do
        if sudo podman push -q --tls-verify=false \
                "localhost:${REG_PORT}/epheo-microshift:candidate"; then break; fi
        if [ "${i}" = "5" ]; then
            echo "ERROR: could not push the candidate to the local registry" >&2
            exit 1
        fi
        sleep 2
    done
fi

# --- 3. Build the qcow2 with bootc-image-builder ------------------------------
log "building qcow2 from ${SRC_IMAGE} (bootc-image-builder)"
sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "${WORKDIR}/config.toml:/config.toml:ro" \
    -v "${WORKDIR}/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB_IMAGE}" \
    --type qcow2 \
    "${SRC_IMAGE}"

DISK="${WORKDIR}/output/qcow2/disk.qcow2"
sudo test -f "${DISK}" || { echo "ERROR: ${DISK} was not produced" >&2; exit 1; }

# --- 4. Boot the VM -----------------------------------------------------------
ACCEL="tcg"
[ -e /dev/kvm ] && ACCEL="kvm"

# Air-gapped first boot is part of the distribution's contract: a fresh
# install must go GREEN with zero guest egress (restrict=on still allows
# the inbound ssh hostfwd). Upgrade mode needs egress to reach the host
# registry at 10.0.2.2 for bootc switch.
# ipv6=off: slirp's fec0:: router advertisement lands before the DHCPv4
# lease, MicroShift then auto-selects IPv6 single-stack with a site-local
# node IP and OVN-K never reaches node readiness. The target sites are
# IPv4; keep the test VM IPv4-only.
NET_RESTRICT="restrict=on,"
[ -n "${UPGRADE_FROM}" ] && NET_RESTRICT=""
log "booting VM (accel=${ACCEL}) with a secondary disk for the storage VG"
sudo truncate --size=2G "${WORKDIR}/lvm-disk.raw"
sudo qemu-system-x86_64 \
    -machine "accel=${ACCEL}" -cpu max -smp "$(nproc)" -m "${VM_MEM}" \
    -drive "file=${DISK},if=virtio,format=qcow2" \
    -drive "file=${WORKDIR}/lvm-disk.raw,if=virtio,format=raw" \
    -netdev "user,id=n0,ipv6=off,${NET_RESTRICT}hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -serial "file:${WORKDIR}/console.log" \
    -display none -daemonize -pidfile "${WORKDIR}/qemu.pid"
QEMU_PID="$(sudo cat "${WORKDIR}/qemu.pid")"

wait_for 600 "ssh into the VM" vssh true

# VG myvg1 with a thin pool named thin is the shape this image turns into an
# r-drbd Pool and default StorageClass by itself. In upgrade mode it is made
# on the previous release, whose TopoLVM uses the same VG.
log "provisioning the storage volume group and thin pool on the secondary disk"
vssh vgcreate -f -y "${VG_NAME}" /dev/vdb
vssh lvcreate -q -y --type thin-pool -l 90%FREE -n thin "${VG_NAME}"

# --- 4b. Upgrade mode: switch to the candidate and reboot ---------------------
if [ -n "${UPGRADE_FROM}" ]; then
    log "assert: booted the previous release via bootc"
    vssh bootc status | grep -qF "${UPGRADE_FROM}"

    # No green gate on the old boot: an old release's own bugs must not be
    # able to fail the candidate's gate. The API is enough for the marker.
    wait_microshift

    log "planting upgrade survival markers (one file on /var, one etcd object)"
    vssh sh -c 'echo pre-upgrade > /var/upgrade-marker'
    koc create configmap upgrade-marker --from-literal=probe=pre-upgrade

    # The candidate's first start backs up the data under the deployment
    # and boot recorded here, and rewrites the version.
    pre_version="$(vssh jq -r .version /var/lib/microshift/version)"
    pre_backup="$(vssh jq -r '.deployment_id + "_" + .boot_id' /var/lib/microshift/version)"
    log "previous release data: version ${pre_version}, backup name ${pre_backup}"

    new_boot() {
        local id
        id="$(vssh cat /proc/sys/kernel/random/boot_id)"
        [ -n "${id}" ] && [ "${id}" != "${old_boot_id}" ]
    }
    upgrade_to_candidate() {
        log "bootc switch to the candidate (pull over the user network)"
        vssh bootc switch "${CANDIDATE_REF}"
        local staged
        staged="$(vssh bootc status --json | jq -r '.status.staged.image.image.image')"
        [ "${staged}" = "${CANDIDATE_REF}" ] || {
            echo "ERROR: staged image is '${staged}', expected '${CANDIDATE_REF}'" >&2
            exit 1
        }
        log "rebooting into the candidate"
        old_boot_id="$(vssh cat /proc/sys/kernel/random/boot_id)"
        vssh reboot || true
        wait_for 600 "VM back from the upgrade reboot" new_boot
    }

    if [ -n "${ROLLBACK}" ]; then
        # Shows how the boots went whether the rollback came or not.
        rollback_report() {
            vssh journalctl --list-boots --no-pager | tail -8 || true
            vssh sh -c 'journalctl -u greenboot-healthcheck --no-pager | grep -iE "counter|rollback|trigger|fallback|imminent|restore|passed|error|vm-test" | tail -40' || true
            vssh grub2-editenv list || true
            vssh ls /var/lib/microshift-backups || true
        }

        # /etc is per deployment: written here, the check reaches the
        # candidate through the /etc merge at the switch, and stays on the
        # previous release too, where it must pass. It waits for the trigger
        # so the candidate first writes data the restore has to undo.
        log "installing a greenboot check that fails on the candidate"
        vssh sh -c "cat > ${FORCE_RED_CHECK} && chmod 755 ${FORCE_RED_CHECK}" <<EOF
#!/bin/bash
[ "\$(bootc status --json | jq -r .status.booted.image.image.image)" = "${CANDIDATE_REF}" ] || exit 0
for _ in \$(seq 180); do
    [ -e ${FORCE_RED_TRIGGER} ] && { echo "vm-test: forced red"; exit 1; }
    sleep 5
done
echo "vm-test: forced red, no trigger after 15m"
exit 1
EOF
        upgrade_to_candidate
        [ "$(booted_image)" = "${CANDIDATE_REF}" ] || {
            echo "ERROR: the first boot after the switch is not the candidate" >&2
            exit 1
        }
        wait_microshift

        want_version="${USHIFT_GITREF%%-*}"
        log "assert: the candidate migrated the data to ${want_version}"
        mid_version="$(vssh jq -r .version /var/lib/microshift/version)"
        [ "${mid_version}" = "${want_version}" ] || {
            echo "ERROR: candidate data version is '${mid_version}'" >&2
            exit 1
        }
        koc create configmap rollback-marker --from-literal=probe=candidate-only
        candidate_digest="$(vssh bootc status --json | jq -r '.status.booted.image.imageDigest')"

        log "forcing greenboot red on the candidate"
        vssh touch "${FORCE_RED_TRIGGER}"
        # About 4 candidate boots (greenboot's 3 retries) then the rollback.
        rolled_back() { [ "$(booted_image)" = "${UPGRADE_FROM}" ]; }
        wait_for 1800 "greenboot rollback to ${UPGRADE_FROM}" rolled_back || {
            rollback_report
            exit 1
        }
        rollback_report

        wait_microshift
        wait_for 600 "greenboot GREEN on the rolled-back boot" greenboot_green || {
            vssh journalctl -b -u greenboot-healthcheck --no-pager | tail -30 || true
            exit 1
        }

        log "assert: MicroShift restored the previous release's data"
        vssh test ! -e /var/lib/microshift-backups/restore || {
            echo "ERROR: the restore marker is still there" >&2
            exit 1
        }
        post_version="$(vssh jq -r .version /var/lib/microshift/version)"
        [ "${post_version}" = "${pre_version}" ] || {
            echo "ERROR: data version is '${post_version}', expected '${pre_version}'" >&2
            exit 1
        }
        koc get configmap upgrade-marker -o jsonpath='{.data.probe}' | grep -q pre-upgrade
        [ -z "$(koc get configmap rollback-marker --ignore-not-found -o name)" ] || {
            echo "ERROR: the candidate's configmap survived the rollback" >&2
            exit 1
        }

        # Else bootc's timer would bring the same image back, red again.
        log "assert: updates now skip the rolled-back image"
        vssh grep -qxF "${candidate_digest}" /var/lib/microshift-update/rolled-back || {
            echo "ERROR: ${candidate_digest} is not in /var/lib/microshift-update/rolled-back" >&2
            exit 1
        }

        # A leftover counter would roll the next update back on its first red.
        log "assert: greenboot cleared its boot counter"
        grubenv="$(vssh grub2-editenv list)"
        if grep -q '^boot_counter=' <<<"${grubenv}"; then
            echo "ERROR: boot_counter left in grubenv:" >&2
            echo "${grubenv}" >&2
            exit 1
        fi

        # The real follow-up: the update comes back (fixed) over restored data.
        log "removing the forced red check; installing the candidate again"
        vssh rm -f "${FORCE_RED_CHECK}" "${FORCE_RED_TRIGGER}"
        pre_backup="$(vssh jq -r '.deployment_id + "_" + .boot_id' /var/lib/microshift/version)"
    fi

    upgrade_to_candidate
fi

# --- 5. Assert this is a real bootc deployment of the candidate ---------------
if [ -n "${UPGRADE_FROM}" ]; then
    log "assert: the booted deployment is the candidate"
    booted="$(booted_image)"
    if [ "${booted}" != "${CANDIDATE_REF}" ]; then
        echo "ERROR: booted image is '${booted}', expected '${CANDIDATE_REF}' (greenboot rollback?)" >&2
        exit 1
    fi
else
    log "assert: booted via bootc from ${DIST_IMAGE}"
    vssh bootc status | grep -q "${DIST_IMAGE}"
fi

wait_microshift

# Pod phases alone pass mid-rollout: an upgrade that changes a DaemonSet
# template leaves its old pod Completed, which looks settled, while the new
# one is not up yet. Every DaemonSet and Deployment must also be fully
# rolled out (observed, updated and available everywhere it is wanted).
rollouts_done() {
    koc get daemonsets,deployments -A -o jsonpath='{range .items[*]}{.metadata.generation}|{.status.observedGeneration}|{.status.desiredNumberScheduled}{.spec.replicas}|{.status.updatedNumberScheduled}{.status.updatedReplicas}|{.status.numberAvailable}{.status.availableReplicas}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' 'NF == 5 { n++; if ($1 != $2 || $4+0 != $3+0 || $5+0 != $3+0) bad = 1 } END { exit (bad || n == 0) }'
}
log "waiting for all pods to be Running/Completed and rollouts done (up to 15m)"
ok=false
total=0 bad=0
for i in $(seq 180); do
    total="$(koc get pods -A --no-headers 2>/dev/null | wc -l)"
    bad="$(unsettled_pods | wc -l)"
    if [ "${total}" -ge 8 ] && [ "${bad}" -eq 0 ] && rollouts_done; then ok=true; break; fi
    # On the upgrade boot greenboot reboots the VM after about 10m, before
    # this wait ends and before dump_diag can reach it: report as it goes.
    if [ $((i % 12)) -eq 0 ]; then
        log "still waiting: ${bad} of ${total} pods not Running/Completed, or a rollout in progress"
        unsettled_pods | head -20 || true
        vssh journalctl -u microshift -b --no-pager 2>/dev/null | grep -i 'kustomiz' | tail -3 || true
    fi
    sleep 5
done
${ok} || { echo "ERROR: pods did not settle (total=${total} not-ready=${bad})" >&2; koc get pods -A || true; exit 1; }

# --- 6. Assert the distribution's opinions ------------------------------------
# The probes below prove each feature works; these name the missing flag
# when one does not.
log "assert: ovnkube-config carries the patched-in flags natively"
ovnkube_conf="$(koc -n openshift-ovn-kubernetes get cm ovnkube-config -o jsonpath='{.data.ovnkube\.conf}')"
for flag in enable-multi-network enable-multi-networkpolicy enable-admin-network-policy \
    enable-egress-firewall; do
    echo "${ovnkube_conf}" | grep -qE "^[[:space:]]*${flag}=true[[:space:]]*$" || {
        echo "ERROR: ${flag}=true missing from ovnkube-config:" >&2
        echo "${ovnkube_conf}" >&2
        exit 1
    }
done

log "assert: the DRBD module is loaded"
vssh grep -q '^drbd ' /proc/modules

# #12: an OS upgrade can ship a new image under the same tag. Simulate it by
# re-pointing the portail tag at a payload image; the import must restore it.
log "assert: a re-pointed embedded tag is re-imported"
store="containers-storage:[overlay@/var/lib/containers/storage+/run/containers/storage]"
portail_ref="$(vssh awk '/\/portail:/ {print $2; exit}' /usr/lib/embedded-images/manifest)"
other_ref="$(vssh awk '$1 ~ /^oci:/ {print $2; exit}' /usr/lib/embedded-images/manifest)"
vssh skopeo copy -q "${store}${other_ref}" "${store}${portail_ref}"
vssh /usr/bin/import-embedded-images.sh | grep -F "importing ${portail_ref} from" >/dev/null

# Rerunning the import must find every manifest entry already in the store:
# proves the boot import covered the whole payload and stayed idempotent.
log "assert: the whole embedded payload is in cri-o's store"
vssh /usr/bin/import-embedded-images.sh | { ! grep -q '^importing'; }

# Functional probes reuse an image already on the node (the OVN-K image):
# no extra registry pull, no docker.io rate limits.
util_img="$(koc -n openshift-ovn-kubernetes get pods -o jsonpath='{.items[0].spec.containers[0].image}')"

# Separates a Pool that never comes up from a PVC that never binds, and
# keeps the pod wait below for provisioning alone.
pool_available() {
    koc get pools -o jsonpath='{range .items[*]}{.spec.vg}={.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' \
        | grep -qx "${VG_NAME}=True"
}
wait_for 300 "Available r-drbd Pool on ${VG_NAME}" pool_available || {
    vssh systemctl status microshift-r-drbd-default-pool --no-pager >&2 || true
    koc get pools -o yaml >&2 || true
    koc -n r-drbd-system get pods >&2 || true
    exit 1
}

log "assert: r-drbd-local is the only default StorageClass"
defaults="$(koc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')"
[ "${defaults}" = "r-drbd-local" ] || {
    echo "ERROR: default StorageClasses are '${defaults}', expected r-drbd-local alone" >&2
    exit 1
}

# No storageClassName: the claim must land on the default class.
log "assert: the default class provisions and mounts a PVC (write + read back)"
koc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-probe
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: pvc-probe
spec:
  restartPolicy: Never
  containers:
  - name: probe
    image: ${util_img}
    command: ["/bin/sh", "-c", "echo probe-ok > /mnt/pvc/probe && exec sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /mnt/pvc
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-probe
EOF
wait_pod_running pvc-probe
koc exec pvc-probe -- cat /mnt/pvc/probe | grep -q probe-ok

log "assert: an OVN-K layer2 secondary network attaches via multus"
koc apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: l2test
spec:
  config: '{"cniVersion": "0.3.1", "name": "l2test", "type": "ovn-k8s-cni-overlay", "topology": "layer2", "subnets": "10.100.200.0/24", "netAttachDefName": "default/l2test"}'
---
apiVersion: v1
kind: Pod
metadata:
  name: l2test-probe
  annotations:
    k8s.v1.cni.cncf.io/networks: l2test
spec:
  restartPolicy: Never
  containers:
  - name: probe
    image: ${util_img}
    command: ["sleep", "3600"]
EOF
wait_pod_running l2test-probe
koc exec l2test-probe -- ip -o addr show dev net1 | grep -q 'inet 10\.100\.200\.' || {
    echo "ERROR: net1 missing or got no address from the l2test subnet" >&2
    koc describe pod l2test-probe >&2 || true
    exit 1
}

# Reachable, cut by the policy, reachable again once it is gone: proves OVN
# enforces it, not that the API merely stores it.
log "assert: a MultiNetworkPolicy isolates a pod on the l2test network"
koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: l2test-server
  labels:
    app: l2test-server
  annotations:
    k8s.v1.cni.cncf.io/networks: l2test
spec:
  restartPolicy: Never
  containers:
  - name: server
    image: ${util_img}
    command: ["python3", "-m", "http.server", "8080"]
EOF
wait_pod_running l2test-server
server_ip="$(koc exec l2test-server -- ip -o -4 addr show dev net1 | awk '{print $4}' | cut -d/ -f1)"
[ -n "${server_ip}" ] || { echo "ERROR: l2test-server got no net1 address" >&2; exit 1; }
l2_reach() {
    koc exec l2test-probe -- python3 -c \
        'import socket, sys; socket.create_connection((sys.argv[1], 8080), 3)' "${target_ip}" \
        >/dev/null 2>&1
}
# Retries cover the server starting and OVN programming or removing ACLs.
l2_expect() {
    local want=$1 got
    for _ in $(seq 20); do
        if l2_reach; then got=yes; else got=no; fi
        [ "${got}" = "${want}" ] && return 0
        sleep 3
    done
    echo "ERROR: l2test-server reachable=${got}, want ${want} ($2)" >&2
    return 1
}
target_ip="${server_ip}"
l2_expect yes "before any policy"
koc apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: l2test-deny
  annotations:
    k8s.v1.cni.cncf.io/policy-for: default/l2test
spec:
  podSelector:
    matchLabels:
      app: l2test-server
  policyTypes: [Ingress]
EOF
l2_expect no "under a deny-all MultiNetworkPolicy"
koc delete multi-networkpolicy l2test-deny >/dev/null
l2_expect yes "after the policy is deleted"

# The same on the cluster network: an admin Deny holds with no NetworkPolicy
# in the namespace, and its removal restores the path.
log "assert: an AdminNetworkPolicy isolates a pod on the cluster network"
target_ip="$(koc get pod l2test-server -o jsonpath='{.status.podIP}')"
[ -n "${target_ip}" ] || { echo "ERROR: l2test-server has no pod IP" >&2; exit 1; }
l2_expect yes "on the cluster network, before any policy"
koc apply -f - <<EOF
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: anptest-deny
spec:
  priority: 10
  subject:
    pods:
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: default
      podSelector:
        matchLabels:
          app: l2test-server
  ingress:
  - name: deny-all
    action: Deny
    from:
    - namespaces: {}
EOF
l2_expect no "under an AdminNetworkPolicy Deny"
koc delete adminnetworkpolicy anptest-deny >/dev/null
l2_expect yes "after the AdminNetworkPolicy is deleted"

# reach NS POD IP PORT: a TCP connect from that pod, 3s timeout.
reach() {
    koc -n "$1" exec "$2" -- python3 -c \
        'import socket, sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 3)' "$3" "$4" \
        >/dev/null 2>&1
}
# expect WANT NS POD IP PORT WHAT: retries cover OVN programming the path.
expect() {
    local want=$1 got
    for _ in $(seq 20); do
        if reach "$2" "$3" "$4" "$5"; then got=yes; else got=no; fi
        [ "${got}" = "${want}" ] && return 0
        sleep 3
    done
    echo "ERROR: $2/$3 to $4:$5 reachable=${got}, want ${want} ($6)" >&2
    return 1
}

# On the default network: a node address cut off for one namespace only,
# and restored when the EgressFirewall goes.
log "assert: an EgressFirewall Deny cuts one namespace off a node address"
node_ip="$(koc get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
koc create namespace efw-probe --dry-run=client -o yaml | koc apply -f - >/dev/null
koc label namespace efw-probe pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: efw-probe
spec:
  restartPolicy: Never
  containers:
  - name: client
    image: ${util_img}
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: efw-target
spec:
  hostNetwork: true
  restartPolicy: Never
  containers:
  - name: server
    image: ${util_img}
    command: ["python3", "-m", "http.server", "18080"]
EOF
wait_pod_running client efw-probe
wait_pod_running efw-target
expect yes efw-probe client "${node_ip}" 18080 "before any EgressFirewall"
koc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: EgressFirewall
metadata:
  name: default
  namespace: efw-probe
spec:
  egress:
  - type: Deny
    to:
      cidrSelector: ${node_ip}/32
EOF
expect no efw-probe client "${node_ip}" 18080 "under an EgressFirewall Deny"
expect yes default l2test-probe "${node_ip}" 18080 "from a namespace without one"
koc -n efw-probe delete egressfirewall default >/dev/null
expect yes efw-probe client "${node_ip}" 18080 "after the EgressFirewall is deleted"

log "assert: the embedded portail image starts from cri-o's store (pull policy Never)"
portail_ref="$(vssh awk '{print $2}' /usr/lib/embedded-images/manifest | grep '/portail:' | head -1)"
koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: portail-probe
spec:
  restartPolicy: Never
  containers:
  - name: portail
    image: ${portail_ref}
    imagePullPolicy: Never
EOF
# Portail needs site config to be useful; the claim under test is that
# kubelet can start a container from the embedded image without any
# registry, so only failures of that mechanism are rejected.
ok=false
for _ in $(seq 24); do
    state="$(koc get pod portail-probe -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)"
    case "${state}" in
        *ErrImageNeverPull*|*CannotRun*|*CreateContainerError*|*StartError*)
            echo "ERROR: embedded portail image did not start: ${state}" >&2
            koc describe pod portail-probe >&2 || true
            exit 1 ;;
        *running*|*terminated*) ok=true; break ;;
    esac
    sleep 5
done
${ok} || {
    echo "ERROR: portail container never started" >&2
    koc describe pod portail-probe >&2 || true
    exit 1
}

# On the upgrade path the previous release may have run the router: the
# candidate must delete it. With it gone, the greenboot gate below is the
# regression cover for patch 0005, the quiet-journal check for 0003.
no_router() {
    local ns
    ns="$(koc get namespace openshift-ingress --ignore-not-found -o name)" && [ -z "${ns}" ]
}
wait_for 180 "router-free cluster (openshift-ingress gone)" no_router || {
    koc -n openshift-ingress get all >&2 || true
    exit 1
}

# The kustomizer applies the CRDs after the core is up and retries, so the
# first attempts can race it.
routes_accepted() {
    koc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata:
  name: tcproute-probe
spec:
  parentRefs:
  - name: probe
  rules:
  - backendRefs:
    - name: probe
      port: 9
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: UDPRoute
metadata:
  name: udproute-probe
spec:
  parentRefs:
  - name: probe
  rules:
  - backendRefs:
    - name: probe
      port: 9
EOF
}
wait_for 180 "TCPRoute and UDPRoute accepted" routes_accepted || {
    koc get crd -o name | grep gateway.networking >&2 || true
    vssh journalctl -u microshift --no-pager | grep -i kustomiz | tail -20 >&2 || true
    exit 1
}

log "assert: RBAC answers as OpenShift 5.0's, experimental routes too (src/rbac)"
koc create rolebinding rbac-probe-view --clusterrole=view --user=rbac-viewer -n default \
    --dry-run=client -o yaml | koc apply -f - >/dev/null
koc create rolebinding rbac-probe-edit --clusterrole=edit --user=rbac-editor -n default \
    --dry-run=client -o yaml | koc apply -f - >/dev/null
koc create rolebinding rbac-probe-admin --clusterrole=admin --user=rbac-admin -n default \
    --dry-run=client -o yaml | koc apply -f - >/dev/null
# The aggregation controller folds the pieces into basic-user, view, edit
# and admin after manifests.d applies them.
can() { [ "$(koc auth can-i "$@" 2>/dev/null)" = yes ]; }
rbac_parity() {
    can list storageclasses.storage.k8s.io --as=rbac-anyone --as-group=system:authenticated &&
        can list volumesnapshotclasses.snapshot.storage.k8s.io --as=rbac-anyone --as-group=system:authenticated &&
        can list httproutes.gateway.networking.k8s.io -n default --as=rbac-viewer &&
        ! can create httproutes.gateway.networking.k8s.io -n default --as=rbac-viewer &&
        can create httproutes.gateway.networking.k8s.io -n default --as=rbac-editor &&
        can create tlsroutes.gateway.networking.k8s.io -n default --as=rbac-editor &&
        can create tcproutes.gateway.networking.k8s.io -n default --as=rbac-editor &&
        can list udproutes.gateway.networking.k8s.io -n default --as=rbac-viewer &&
        can list network-attachment-definitions.k8s.cni.cncf.io -n default --as=rbac-admin &&
        ! can list network-attachment-definitions.k8s.cni.cncf.io -n default --as=rbac-editor &&
        # OpenShift leaves EgressFirewall to cluster admins; dotvirt grants it
        # to project admins with a role of its own, which relies on this.
        ! can create egressfirewalls.k8s.ovn.org -n default --as=rbac-admin &&
        # OVN-K's host-network-namespace, whose label NetworkPolicies admit
        # host-network sources by (a host-network Gateway data plane).
        koc get namespace -l policy-group.network.openshift.io/host-network -o name | grep -qx namespace/openshift-host-network
}
wait_for 180 "RBAC answers as OpenShift's" rbac_parity || {
    koc get clusterrole basic-user view edit admin -o name >&2 || true
    vssh journalctl -u microshift --no-pager | grep -i kustomiz | tail -20 >&2 || true
    exit 1
}

if [ -n "${UPGRADE_FROM}" ]; then
    log "assert: data survived the upgrade (/var file + etcd object)"
    vssh cat /var/upgrade-marker | grep -q pre-upgrade
    koc get configmap upgrade-marker -o jsonpath='{.data.probe}' | grep -q pre-upgrade

    # A rollback can only restore what the candidate backed up, and a version
    # file still at the old release means the data was never migrated.
    want_version="${USHIFT_GITREF%%-*}"
    log "assert: data version is ${want_version} (was ${pre_version})"
    post_version="$(vssh jq -r .version /var/lib/microshift/version)"
    [ "${post_version}" = "${want_version}" ] || {
        echo "ERROR: data version is '${post_version}', expected '${want_version}'" >&2
        exit 1
    }

    log "assert: the pre-upgrade data was backed up as ${pre_backup}"
    vssh test -d "/var/lib/microshift-backups/${pre_backup}" || {
        echo "ERROR: no backup of the pre-upgrade data" >&2
        vssh ls -la /var/lib/microshift-backups >&2 || true
        exit 1
    }
fi

# The log line alone is implementation-specific; boot_success=1 in grubenv
# below is the actual contract.
wait_for 300 "greenboot GREEN on this boot" greenboot_green || {
    vssh journalctl -b -u greenboot-healthcheck --no-pager | tail -30 || true
    exit 1
}

log "assert: grubenv records boot_success=1"
vssh grub2-editenv list | grep -q 'boot_success=1'

# multinode-test proves the follow itself; this is the controller's half on
# every lane, read with a kubelet's credential as a worker reads it.
want_image="$(vssh bootc status --json | jq -r '.status.booted.image
    | (.image.image | sub("@.*$"; "") | sub(":[^:/]*$"; "")) + "@" + .imageDigest')"
published_image() {
    [ "$(vssh oc --kubeconfig /var/lib/microshift/resources/kubelet/kubeconfig \
        -n kube-public get configmap microshift-update -o jsonpath='{.data.image}')" = "${want_image}" ]
}
wait_for 180 "kube-public/microshift-update to name ${want_image}" published_image || {
    vssh journalctl -b -u microshift-update-publish --no-pager | tail -20 || true
    exit 1
}

log "assert: a node's own credential names it, reads the Volumes, and may take the free update lock"
NODE_KCFG=/var/lib/microshift/resources/kubelet/kubeconfig
vssh oc --kubeconfig "${NODE_KCFG}" auth whoami -o jsonpath='{.status.userInfo.username}' \
    | grep '^system:node:' >/dev/null
vssh oc --kubeconfig "${NODE_KCFG}" get volumes.r-drbd.io -o name >/dev/null
lock_holder="$(vssh oc --kubeconfig "${NODE_KCFG}" -n kube-public get configmap microshift-update-lock \
    -o jsonpath='{.data.holder}')"
[ -z "${lock_holder}" ] || { echo "ERROR: the update lock is held by '${lock_holder}'" >&2; exit 1; }
# A server dry run passes admission too: auth can-i would miss NodeRestriction,
# which refuses a node every Lease but its own.
vssh sh -c "oc --kubeconfig ${NODE_KCFG} -n kube-public get configmap microshift-update-lock -o json \
    | oc --kubeconfig ${NODE_KCFG} replace --dry-run=server -f -" >/dev/null

log "assert: no failed systemd units"
failed="$(vssh systemctl --failed --no-legend | wc -l)"
[ "${failed}" -eq 0 ] || {
    echo "ERROR: ${failed} systemd unit(s) failed:" >&2
    vssh systemctl --failed >&2 || true
    exit 1
}

# Regression cover for patches 0002/0003 ("logs are signal, not noise"):
# both fail as runaway journal volume, and both could silently return if a
# bump lets a patch apply cleanly against code that moved. 500 lines/2m is
# about 10x quiet steady state and 100x under a hot loop. No message-text
# greps: wording changes across the auto-bumped z-streams. The fresh lane
# runs the same binary, so the upgrade lanes skip the 2m wait.
if [ -z "${UPGRADE_FROM}" ]; then
    log "assert: journal is quiet at steady state (2m window)"
    sleep 120
    lines="$(vssh journalctl --since=-2min --no-pager | wc -l)"
    [ "${lines}" -lt 500 ] || {
        echo "ERROR: ${lines} journal lines in 2m, log noise regression?" >&2
        vssh journalctl --since=-2min --no-pager | tail -40 || true
        exit 1
    }
fi

log "VM ${UPGRADE_FROM:+UPGRADE }TEST PASSED"
