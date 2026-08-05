#!/bin/bash
# Two privileged containers on one podman network: a controller (default
# profile) and a worker joined with 'microshift add-node --worker'. Asserts
# the join mechanics the single-node smoke cannot:
#   - the worker holds no signing material (no ca.key, no SA key)
#   - the kubelet bootstraps client + serving certs through CSRs and the
#     controller's kubelet-csr-approver approves them
#   - apiserver -> kubelet TLS works with the CSR-issued serving cert
#   - OVN and DNS daemonsets land and run on the worker
#   - 'microshift healthcheck' gates on the worker's own readiness
# bootc deployment and greenboot boot-gating remain vm-test territory.
#
# Usage: DIST_IMAGE=epheo-microshift ./scripts/multinode-smoke.sh
#        CLEAN=1 ./scripts/multinode-smoke.sh
set -euo pipefail

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
NET="${NET:-epheo-microshift-mn}"
CTRL="${CTRL:-epheo-mn-controller}"
WORKER="${WORKER:-epheo-mn-worker}"
LVM_DISK="${LVM_DISK:-/var/lib/epheo-microshift-smoke/lvmdisk.image}"
VG_NAME="myvg1" # must match the device-class in the packaged lvmd config
KUBECONFIG_IN_CONTAINER="/var/lib/microshift/resources/kubeadmin/kubeconfig"

log() { echo "--- $*"; }

cexec() { sudo podman exec -i "${CTRL}" "$@"; }
wexec() { sudo podman exec -i "${WORKER}" "$@"; }
koc() { cexec oc --kubeconfig "${KUBECONFIG_IN_CONTAINER}" "$@"; }

clean() {
    sudo podman rm -f "${CTRL}" "${WORKER}" 2>/dev/null || true
    sudo podman network rm -f "${NET}" 2>/dev/null || true
    # The loopback VG is shared with the single-node smoke; leave it in place.
}

diagnostics() {
    log "DIAGNOSTICS: nodes"
    koc get nodes -o wide 2>&1 || true
    log "DIAGNOSTICS: pods"
    koc get pods -A -o wide 2>&1 || true
    log "DIAGNOSTICS: csr"
    koc get csr 2>&1 || true
    # The journals only show kubelet-level restarts; the actual crash reason
    # lives in the container logs of whatever is not Running/Ready.
    koc get pods -A --no-headers 2>/dev/null | awk '
        $4=="Completed" || $4=="Succeeded" {next}
        {split($3,a,"/"); if ($4!="Running" || a[1]!=a[2]) print $1" "$2}' \
    | while read -r ns pod; do
        log "DIAGNOSTICS: logs of ${ns}/${pod} (last 60 lines per container)"
        koc logs -n "${ns}" "${pod}" --all-containers --tail=60 2>&1 || true
        koc logs -n "${ns}" "${pod}" --all-containers --tail=30 --previous 2>&1 || true
    done
    log "DIAGNOSTICS: controller microshift journal (last 40 lines)"
    cexec journalctl -u microshift --no-pager -n 40 2>&1 || true
    log "DIAGNOSTICS: worker microshift journal (last 80 lines)"
    wexec journalctl -u microshift --no-pager -n 80 2>&1 || true
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
sudo modprobe geneve || true

if [ ! -f "${LVM_DISK}" ]; then
    log "creating loopback VG '${VG_NAME}' for TopoLVM"
    sudo mkdir -p "$(dirname "${LVM_DISK}")"
    sudo truncate --size=2G "${LVM_DISK}"
    dev="$(sudo losetup --find --show --nooverlap "${LVM_DISK}")"
    sudo vgcreate -f -y "${VG_NAME}" "${dev}"
fi

# --- 3. Boot the two nodes --------------------------------------------------
clean
sudo podman network create "${NET}" >/dev/null

vol_opts=(--tty --volume /dev:/dev)
for device in input snd dri; do
    [ -d "/dev/${device}" ] && vol_opts+=(--tmpfs "/dev/${device}")
done
run_opts=(--privileged
    --ulimit nofile=524288:524288
    --dns-search=.
    "${vol_opts[@]}"
    --tmpfs /var/lib/containers
    --network "${NET}")

log "starting ${CTRL} (controller profile)"
sudo podman run -d "${run_opts[@]}" \
    --name "${CTRL}" --hostname "${CTRL}" "${DIST_IMAGE}" >/dev/null

# The worker profile must be in place before systemd first starts microshift,
# or the node boots a full control plane and leaves stale data behind.
log "creating ${WORKER} with the worker profile pre-installed"
sudo podman create "${run_opts[@]}" \
    --name "${WORKER}" --hostname "${WORKER}" "${DIST_IMAGE}" >/dev/null
# The image ships no microshift.service.d, and podman cp will not create a
# missing destination dir, so copy a whole directory into the existing
# /etc/systemd/system/ (this mirrors what microshift-profile worker writes).
ovdir="$(mktemp -d)"
mkdir -p "${ovdir}/microshift.service.d"
printf '[Service]\nExecStart=\nExecStart=microshift run --multinode --worker\n' \
    > "${ovdir}/microshift.service.d/50-profile-worker.conf"
sudo podman cp "${ovdir}/microshift.service.d" "${WORKER}:/etc/systemd/system/"
rm -rf "${ovdir}"
sudo podman start "${WORKER}" >/dev/null

trap 'rc=$?; [ ${rc} -ne 0 ] && diagnostics; exit ${rc}' EXIT

wait_active() { # container-name unit
    for _ in $(seq 60); do
        sudo podman exec -i "$1" systemctl is-active -q "$2" 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

log "waiting for the controller's microshift.service (up to 5m)"
wait_active "${CTRL}" microshift.service \
    || { echo "ERROR: controller microshift.service did not become active" >&2; exit 1; }

log "waiting for the controller node to be Ready (up to 5m)"
ok=false
for _ in $(seq 60); do
    if koc get node 2>/dev/null | grep -q ' Ready '; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: controller node never became Ready" >&2; exit 1; }

log "waiting for the controller's pods to settle (up to 10m)"
ok=false
for _ in $(seq 120); do
    total="$(koc get pods -A --no-headers 2>/dev/null | wc -l)"
    bad="$(koc get pods -A --no-headers 2>/dev/null | grep -cvE 'Running|Completed' || true)"
    if [ "${total}" -ge 8 ] && [ "${bad}" -eq 0 ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: controller pods did not settle (total=${total} not-ready=${bad})" >&2; exit 1; }

# --- 4. Join the worker ------------------------------------------------------
log "assert: worker profile is detected"
[ "$(wexec microshift-profile | tr -d '[:space:]')" = "worker" ]

# The hostname kubeadmin kubeconfig: its URL resolves over the podman network
# and the external serving cert covers the hostname.
log "fetching the bootstrap kubeconfig from the controller"
boot_kc="$(mktemp)"
cexec cat "/var/lib/microshift/resources/kubeadmin/${CTRL}/kubeconfig" > "${boot_kc}"
sudo podman cp "${boot_kc}" "${WORKER}:/tmp/bootstrap-kubeconfig"
rm -f "${boot_kc}"

log "joining the worker (microshift add-node --worker, up to 10m)"
wexec microshift add-node --worker --kubeconfig /tmp/bootstrap-kubeconfig

# --- 5. Assert the worker's shape --------------------------------------------
log "assert: worker node is Ready"
koc get node "${WORKER}" --no-headers | grep -q ' Ready '

log "assert: worker is labeled worker, not control-plane"
labels="$(koc get node "${WORKER}" -o jsonpath='{.metadata.labels}')"
echo "${labels}" | grep -q 'node-role.kubernetes.io/worker' \
    || { echo "ERROR: worker is missing the worker role label" >&2; exit 1; }
# A bare '! ... | grep -q' is a no-op under set -e, so test the presence
# explicitly and fail on a match.
if echo "${labels}" | grep -q 'node-role.kubernetes.io/control-plane'; then
    echo "ERROR: worker carries the control-plane label" >&2; exit 1
fi

log "assert: no signing material on the worker"
# wexec must succeed for the check to be meaningful; a failed exec inverted by
# '!' would otherwise read as 'no key found'.
if wexec sh -c "find /var/lib/microshift/certs -name ca.key 2>/dev/null | grep -q ."; then
    echo "ERROR: CA private key found on the worker" >&2; exit 1
fi
if wexec test -f /var/lib/microshift/resources/kube-apiserver/secrets/service-account-key/service-account.key; then
    echo "ERROR: service account key found on the worker" >&2; exit 1
fi

log "assert: kubelet serving CSR was approved and issued (up to 2m)"
# The approver ticks every 30s and node-Ready does not depend on the serving
# cert, so poll rather than checking once.
ok=false
for _ in $(seq 24); do
    if koc get csr -o wide 2>/dev/null | grep "system:node:${WORKER}" | grep kubelet-serving | grep -q 'Approved,Issued'; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: kubelet serving CSR was not approved+issued" >&2; exit 1; }

log "assert: apiserver reaches the worker kubelet over the CSR-issued cert (up to 2m)"
ok=false
for _ in $(seq 24); do
    if [ "$(koc get --raw "/api/v1/nodes/${WORKER}/proxy/healthz" 2>/dev/null)" = "ok" ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: node proxy healthz never answered" >&2; exit 1; }

log "assert: OVN and DNS pods run and are ready on the worker (up to 10m)"
ok=false
for _ in $(seq 120); do
    stats="$(koc get pods -A -o wide --no-headers --field-selector "spec.nodeName=${WORKER}" 2>/dev/null)"
    on_worker_total="$(echo "${stats}" | grep -c . || true)"
    # A Running-but-unready (x/y, x<y) pod is not settled; STATUS alone lies.
    # Columns (-A -o wide): 1 NS, 2 NAME, 3 READY, 4 STATUS.
    on_worker_bad="$(echo "${stats}" | awk '
        $4=="Completed" || $4=="Succeeded" {next}
        $4!="Running" {c++; next}
        {split($3,a,"/"); if (a[1]!=a[2]) c++}
        END {print c+0}')"
    if [ "${on_worker_total}" -ge 2 ] && [ "${on_worker_bad}" -eq 0 ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: workloads on the worker did not settle (total=${on_worker_total} not-ready=${on_worker_bad})" >&2; exit 1; }
# An OVN node pod must be Running AND fully ready on the worker (columns without
# -A: 1 NAME, 2 READY, 3 STATUS).
koc get pods -n openshift-ovn-kubernetes -o wide --no-headers --field-selector "spec.nodeName=${WORKER}" \
    | awk '$3=="Running" {split($2,a,"/"); if (a[1]==a[2] && a[2]>0) f=1} END {exit f?0:1}' \
    || { echo "ERROR: no ready OVN pod on the worker" >&2; exit 1; }

log "assert: worker healthcheck gates on its own readiness"
wexec microshift healthcheck -v=2 --timeout=120s

log "MULTINODE SMOKE TEST PASSED"
