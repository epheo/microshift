#!/bin/bash
# Boot the distro image as a privileged podman container and assert that the
# distribution's opinions actually hold at runtime:
#   - MicroShift comes up healthy with OVN-Kubernetes as the CNI
#   - ovnkube-config carries enable-multi-network=true (patches/0001, applied
#     at the source — no runtime ConfigMap patching)
#   - multus is deployed
#   - TopoLVM is deployed (loopback VG backend)
#   - the embedded portail image was imported into cri-o's store at boot
#   - the greenboot MicroShift health gate is enabled
#
# Container run flags follow microshift-io/microshift src/cluster_manager.sh.
# Requires root (sudo) — MicroShift needs real privileges (OVS, cgroups).
#
# Usage: DIST_IMAGE=epheo-microshift ./scripts/smoke-test.sh
#        CLEAN=1 ./scripts/smoke-test.sh   # tear down the smoke container/VG
set -euo pipefail

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
NAME="${NAME:-epheo-microshift-smoke}"
LVM_DISK="${LVM_DISK:-/var/lib/epheo-microshift-smoke/lvmdisk.image}"
VG_NAME="myvg1" # must match the device-class in the packaged lvmd config
KUBECONFIG_IN_CONTAINER="/var/lib/microshift/resources/kubeadmin/kubeconfig"

log() { echo "--- $*"; }

pexec() { sudo podman exec -i "${NAME}" "$@"; }

koc() { pexec oc --kubeconfig "${KUBECONFIG_IN_CONTAINER}" "$@"; }

clean() {
    sudo podman rm -f "${NAME}" 2>/dev/null || true
    if [ -f "${LVM_DISK}" ]; then
        sudo vgremove -f -y "${VG_NAME}" 2>/dev/null || true
        local dev
        dev="$(sudo losetup -j "${LVM_DISK}" | cut -d: -f1)"
        [ -n "${dev}" ] && sudo losetup -d "${dev}" 2>/dev/null || true
        sudo rm -rf "$(dirname "${LVM_DISK}")"
    fi
}

diagnostics() {
    log "DIAGNOSTICS: pods"
    koc get pods -A -o wide 2>&1 || true
    log "DIAGNOSTICS: microshift journal (last 80 lines)"
    pexec journalctl -u microshift --no-pager -n 80 2>&1 || true
    log "DIAGNOSTICS: import-embedded-images journal"
    pexec journalctl -u import-embedded-images --no-pager -n 20 2>&1 || true
}

if [ "${CLEAN:-0}" = "1" ]; then
    clean
    log "cleaned up"
    exit 0
fi

# --- 1. Make the image available to rootful podman -------------------------
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

# --- 2. Host prerequisites --------------------------------------------------
sudo modprobe openvswitch || true

if [ ! -f "${LVM_DISK}" ]; then
    log "creating loopback VG '${VG_NAME}' for TopoLVM"
    sudo mkdir -p "$(dirname "${LVM_DISK}")"
    sudo truncate --size=2G "${LVM_DISK}"
    dev="$(sudo losetup --find --show --nooverlap "${LVM_DISK}")"
    sudo vgcreate -f -y "${VG_NAME}" "${dev}"
fi

# --- 3. Boot the image as a container ---------------------------------------
sudo podman rm -f "${NAME}" 2>/dev/null || true
log "starting ${NAME} from ${DIST_IMAGE}"
vol_opts=(--tty --volume /dev:/dev)
for device in input snd dri; do
    [ -d "/dev/${device}" ] && vol_opts+=(--tmpfs "/dev/${device}")
done
sudo podman run --privileged -d \
    --ulimit nofile=524288:524288 \
    --dns-search=. \
    "${vol_opts[@]}" \
    --tmpfs /var/lib/containers \
    --name "${NAME}" \
    --hostname "${NAME}" \
    "${DIST_IMAGE}" >/dev/null

trap 'rc=$?; [ ${rc} -ne 0 ] && diagnostics; exit ${rc}' EXIT

log "waiting for dbus"
for _ in $(seq 60); do
    pexec systemctl is-active -q dbus.service 2>/dev/null && break
    sleep 1
done

log "waiting for microshift.service (up to 5m)"
ok=false
for _ in $(seq 60); do
    if pexec systemctl is-active -q microshift.service 2>/dev/null; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: microshift.service did not become active" >&2; exit 1; }

log "waiting for the node to be Ready (up to 5m)"
ok=false
for _ in $(seq 60); do
    if koc get node 2>/dev/null | grep -q ' Ready '; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: node never became Ready" >&2; exit 1; }

log "waiting for all pods to be Running/Completed (up to 10m)"
ok=false
for _ in $(seq 120); do
    total="$(koc get pods -A --no-headers 2>/dev/null | wc -l)"
    bad="$(koc get pods -A --no-headers 2>/dev/null | grep -cvE 'Running|Completed' || true)"
    if [ "${total}" -ge 8 ] && [ "${bad}" -eq 0 ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: pods did not settle (total=${total} not-ready=${bad})" >&2; exit 1; }

# --- 4. Assert the distribution's opinions ----------------------------------
log "assert: OVN-Kubernetes is the CNI"
koc -n openshift-ovn-kubernetes get pods --no-headers | grep -q Running

log "assert: enable-multi-network=true is native in ovnkube-config"
koc -n openshift-ovn-kubernetes get cm ovnkube-config -o jsonpath='{.data.ovnkube\.conf}' \
    | grep -q 'enable-multi-network=true'

log "assert: multus is deployed"
koc -n openshift-multus get daemonset multus --no-headers >/dev/null

log "assert: TopoLVM is running"
koc -n topolvm-system get pods --no-headers | grep -q Running

log "assert: embedded portail image was imported into cri-o at boot"
pexec crictl images | grep -q 'localhost/embedded/portail'

log "assert: greenboot MicroShift health gate is enabled"
pexec test -x /etc/greenboot/check/required.d/40_microshift_running_check.sh

log "SMOKE TEST PASSED"
