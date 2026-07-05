#!/bin/bash
# The canonical acceptance test: turn the bootc image into a qcow2 disk with
# bootc-image-builder, boot it as a real VM under QEMU/KVM, and assert the
# distribution's opinions on a genuine boot — bootloader, ostree deployment,
# systemd boot order, and greenboot actually gating the boot. This is what
# `make smoke` (privileged container, fast local iteration) cannot validate.
#
# Requires root-capable podman (bootc-image-builder is a privileged container
# reading the root containers-storage) and qemu-system-x86_64. Uses KVM when
# /dev/kvm exists, falls back to TCG (slow) otherwise.
#
# Usage: DIST_IMAGE=epheo-microshift ./scripts/vm-test.sh
set -euo pipefail

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
WORKDIR="${WORKDIR:-/tmp/epheo-microshift-vm}"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEM="${VM_MEM:-8192}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
VG_NAME="myvg1" # must match the device-class in the packaged lvmd config

log() { echo "--- $*"; }

QEMU_PID=""
cleanup() {
    rc=$?
    [ -n "${QEMU_PID}" ] && sudo kill "${QEMU_PID}" 2>/dev/null || true
    if [ ${rc} -ne 0 ]; then
        log "FAILED (rc=${rc}) — last 60 lines of VM console:"
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

# --- 1. Prepare the workdir, ssh key and builder config ----------------------
sudo rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/output"
ssh-keygen -q -t ed25519 -N '' -f "${WORKDIR}/id"
cat > "${WORKDIR}/config.toml" <<EOF
[[customizations.user]]
name = "root"
key = "$(cat "${WORKDIR}/id.pub")"
EOF

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

# --- 3. Build the qcow2 with bootc-image-builder ------------------------------
log "building qcow2 from ${DIST_IMAGE} (bootc-image-builder)"
sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "${WORKDIR}/config.toml:/config.toml:ro" \
    -v "${WORKDIR}/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB_IMAGE}" \
    --type qcow2 \
    "localhost/${DIST_IMAGE}:latest"

DISK="${WORKDIR}/output/qcow2/disk.qcow2"
sudo test -f "${DISK}" || { echo "ERROR: ${DISK} was not produced" >&2; exit 1; }

# --- 4. Boot the VM -----------------------------------------------------------
ACCEL="tcg"
[ -e /dev/kvm ] && ACCEL="kvm"
log "booting VM (accel=${ACCEL}) with a secondary disk for the TopoLVM VG"
sudo truncate --size=2G "${WORKDIR}/lvm-disk.raw"
sudo qemu-system-x86_64 \
    -machine "accel=${ACCEL}" -cpu max -smp "$(nproc)" -m "${VM_MEM}" \
    -drive "file=${DISK},if=virtio,format=qcow2" \
    -drive "file=${WORKDIR}/lvm-disk.raw,if=virtio,format=raw" \
    -netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -serial "file:${WORKDIR}/console.log" \
    -display none -daemonize -pidfile "${WORKDIR}/qemu.pid"
QEMU_PID="$(sudo cat "${WORKDIR}/qemu.pid")"

log "waiting for ssh (up to 10m)"
ok=false
for _ in $(seq 120); do
    if vssh true 2>/dev/null; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: VM never became reachable over ssh" >&2; exit 1; }

# --- 5. Assert this is a real bootc deployment of our image -------------------
log "assert: booted via bootc from ${DIST_IMAGE}"
vssh bootc status | grep -q "${DIST_IMAGE}"

log "provisioning the TopoLVM volume group on the secondary disk"
vssh vgcreate -f -y "${VG_NAME}" /dev/vdb

log "waiting for microshift.service (up to 5m)"
ok=false
for _ in $(seq 60); do
    if vssh systemctl is-active -q microshift.service 2>/dev/null; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: microshift.service did not become active" >&2; exit 1; }

KCFG=/var/lib/microshift/resources/kubeadmin/kubeconfig
koc() { vssh oc --kubeconfig "${KCFG}" "$@"; }

log "waiting for the node to be Ready (up to 5m)"
ok=false
for _ in $(seq 60); do
    if koc get node 2>/dev/null | grep -q ' Ready '; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: node never became Ready" >&2; exit 1; }

log "waiting for all pods to be Running/Completed (up to 15m)"
ok=false
total=0 bad=0
for _ in $(seq 180); do
    total="$(koc get pods -A --no-headers 2>/dev/null | wc -l)"
    bad="$(koc get pods -A --no-headers 2>/dev/null | grep -cvE 'Running|Completed' || true)"
    if [ "${total}" -ge 8 ] && [ "${bad}" -eq 0 ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: pods did not settle (total=${total} not-ready=${bad})" >&2; koc get pods -A || true; exit 1; }

# --- 6. Assert the distribution's opinions ------------------------------------
log "assert: OVN-Kubernetes is the CNI"
koc -n openshift-ovn-kubernetes get pods --no-headers | grep -q Running

log "assert: enable-multi-network=true is native in ovnkube-config"
koc -n openshift-ovn-kubernetes get cm ovnkube-config -o jsonpath='{.data.ovnkube\.conf}' \
    | grep -q 'enable-multi-network=true' || {
        echo "ERROR: enable-multi-network missing from ovnkube-config:" >&2
        koc -n openshift-ovn-kubernetes get cm ovnkube-config -o yaml | head -40 >&2 || true
        exit 1
    }

log "assert: multus is deployed"
koc -n openshift-multus get daemonset multus --no-headers >/dev/null

log "assert: TopoLVM is running"
koc -n topolvm-system get pods --no-headers | grep -q Running

log "assert: embedded portail image was imported into cri-o at boot"
vssh crictl images | grep -q 'localhost/embedded/portail'

# The log phrasing differs between greenboot implementations (bash: "Boot
# Status is GREEN"; the CS10 Rust rewrite: "greenboot health-check passed") —
# accept both, then assert the actual contract: boot_success=1 in grubenv.
log "assert: greenboot health checks passed (up to 5m)"
ok=false
for _ in $(seq 60); do
    if vssh journalctl -u greenboot-healthcheck --no-pager 2>/dev/null \
            | grep -qiE 'Status is GREEN|health-check passed'; then
        ok=true; break
    fi
    sleep 5
done
${ok} || {
    echo "ERROR: greenboot health checks did not pass" >&2
    vssh journalctl -u greenboot-healthcheck --no-pager | tail -30 || true
    exit 1
}

log "assert: grubenv records boot_success=1"
vssh grub2-editenv list | grep -q 'boot_success=1'

log "VM TEST PASSED"
