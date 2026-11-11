#!/bin/bash
# Two privileged containers on one podman network: a controller (default
# profile) and a worker joined with 'microshift add-node --worker'. Asserts
# the join mechanics the single-node smoke cannot:
#   - the worker joins with a short-lived token that can create CSRs and
#     nothing an admin could, and holds no signing material
#   - the kubelet bootstraps client + serving certs through CSRs and the
#     controller's kubelet-csr-approver approves them
#   - apiserver -> kubelet TLS works with the CSR-issued serving cert
#   - OVN and DNS daemonsets land and run on the worker
#   - the zone pods' account, which every worker holds, writes nothing
#     outside openshift-ovn-kubernetes but pod and node status
#   - 'microshift healthcheck' gates on the worker's own readiness
# bootc deployment and greenboot boot-gating remain vm-test territory.
#
# Usage: DIST_IMAGE=epheo-microshift ./scripts/multinode-smoke.sh
#        CLEAN=1 ./scripts/multinode-smoke.sh
set -euo pipefail
# shellcheck source=scripts/lib-container-nic.sh
source "$(dirname "$0")/lib-container-nic.sh"

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
NET="${NET:-epheo-microshift-mn}"
NET_PREFIX="${NET_PREFIX:-10.89.201}"
CTRL_IP="${NET_PREFIX}.10"
WORKER_IP="${NET_PREFIX}.11"
CTRL="${CTRL:-epheo-mn-controller}"
WORKER="${WORKER:-epheo-mn-worker}"
LVM_DISK="${LVM_DISK:-/var/lib/epheo-microshift-smoke/lvmdisk.image}"
VG_NAME="myvg1" # the VG microshift-r-drbd-default-pool turns into a Pool
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

# OVS runs outside MicroShift, which only validates br-ex and exits, so an OVS
# failure reads as a bare "microshift.service did not become active" with no
# cause in the microshift journal. No bootc or SELinux state here: these are
# containers, on a runner that has neither.
ovs_diag() { # ovs_diag <cexec|wexec> <name> -- <exec-fn> <label>, same order as lib-diag.sh
    local fn=$1 name=$2
    log "DIAGNOSTICS: ${name} OVS units, bridge, failed units"
    for u in openvswitch ovsdb-server ovs-vswitchd microshift-ovs-init NetworkManager; do
        echo "--- ${name}: journalctl -u ${u} (last 40 lines)"
        ${fn} journalctl -u "${u}" --no-pager -n 40 2>&1 || true
    done
    echo "--- ${name}: ovs-vsctl show"
    ${fn} ovs-vsctl --timeout=5 show 2>&1 || true
    echo "--- ${name}: ip -br addr"
    ${fn} ip -br addr 2>&1 || true
    echo "--- ${name}: failed units"
    ${fn} systemctl list-units --failed --no-pager 2>&1 || true
}

diagnostics() {
    log "DIAGNOSTICS: nodes"
    koc get nodes -o wide 2>&1 || true
    log "DIAGNOSTICS: pods"
    koc get pods -A -o wide 2>&1 || true
    log "DIAGNOSTICS: csr"
    koc get csr 2>&1 || true
    log "DIAGNOSTICS: events (FailedCreatePodSandBox carries the CNI error)"
    koc get events -A --sort-by='.metadata.creationTimestamp' 2>&1 | tail -50 || true
    # The OVN pods are the CNI brain; dump them even when Ready, since a
    # hanging CNI ADD leaves them green while everything else is stuck.
    koc get pods -n openshift-ovn-kubernetes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | while read -r pod; do
        log "DIAGNOSTICS: logs of openshift-ovn-kubernetes/${pod} (last 80 lines per container, errors and tail)"
        koc logs -n openshift-ovn-kubernetes "${pod}" --all-containers --tail=-1 </dev/null 2>&1 | grep -E '^[EFW][0-9]{4}|error|failed' | tail -30 || true
        koc logs -n openshift-ovn-kubernetes "${pod}" --all-containers --tail=25 </dev/null 2>&1 || true
    done
    # The journals only show kubelet-level restarts; the actual crash reason
    # lives in the container logs of whatever is not Running/Ready.
    koc get pods -A --no-headers 2>/dev/null | awk '
        $4=="Completed" || $4=="Succeeded" {next}
        {split($3,a,"/"); if ($4!="Running" || a[1]!=a[2]) print $1" "$2}' \
    | while read -r ns pod; do
        log "DIAGNOSTICS: logs of ${ns}/${pod} (last 60 lines per container)"
        # </dev/null: cexec runs podman exec -i, which otherwise swallows the
        # pod list feeding this loop and only the first pod gets dumped.
        koc logs -n "${ns}" "${pod}" --all-containers --tail=60 </dev/null 2>&1 || true
        koc logs -n "${ns}" "${pod}" --all-containers --tail=30 --previous </dev/null 2>&1 || true
    done
    log "DIAGNOSTICS: controller microshift journal (last 40 lines)"
    cexec journalctl -u microshift --no-pager -n 40 2>&1 || true
    log "DIAGNOSTICS: worker microshift journal (last 80 lines)"
    wexec journalctl -u microshift --no-pager -n 80 2>&1 || true
    ovs_diag cexec controller
    ovs_diag wexec worker
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
    log "creating loopback VG '${VG_NAME}' and thin pool thin for r-drbd"
    sudo mkdir -p "$(dirname "${LVM_DISK}")"
    sudo truncate --size=2G "${LVM_DISK}"
    dev="$(sudo losetup --find --show --nooverlap "${LVM_DISK}")"
    sudo vgcreate -f -y "${VG_NAME}" "${dev}"
    sudo lvcreate -q -y --type thin-pool -l 90%FREE -n thin "${VG_NAME}"
fi

# --- 3. Boot the two nodes --------------------------------------------------
clean
nic_network "${NET}" "${NET_PREFIX}"

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
sudo podman create "${run_opts[@]}" --ip "${CTRL_IP}" \
    --name "${CTRL}" --hostname "${CTRL}" "${DIST_IMAGE}" >/dev/null
nic_install "${CTRL}" "${CTRL_IP}" "${NET_PREFIX}.1"
sudo podman start "${CTRL}" >/dev/null

# The worker profile must be in place before systemd first starts microshift,
# or the node boots a full control plane and leaves stale data behind.
log "creating ${WORKER} with the worker profile pre-installed"
sudo podman create "${run_opts[@]}" --ip "${WORKER_IP}" \
    --name "${WORKER}" --hostname "${WORKER}" "${DIST_IMAGE}" >/dev/null
nic_install "${WORKER}" "${WORKER_IP}" "${NET_PREFIX}.1"
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

# The hostname resolves over the podman network and the controller's external
# serving cert covers it.
log "minting a join kubeconfig on the controller"
boot_kc="$(mktemp)"
cexec microshift worker-join-kubeconfig --address "${CTRL}" --duration 30m > "${boot_kc}"
sudo podman cp "${boot_kc}" "${WORKER}:/tmp/bootstrap-kubeconfig"
rm -f "${boot_kc}"

# The join token replaces the cluster-admin kubeconfig. Creating CSRs is the
# control: it proves the probe reads RBAC rather than failing to connect.
log "assert: the join token creates CSRs and nothing an admin could"
can_join() { wexec oc --kubeconfig /tmp/bootstrap-kubeconfig auth can-i "$@" 2>/dev/null || true; }
[ "$(can_join create certificatesigningrequests)" = yes ] \
    || { echo "ERROR: the join token cannot create CSRs; the probe below proves nothing" >&2; exit 1; }
for probe in "get secrets -n kube-system" "create pods -n default" \
        "update configmaps -n kube-system" "list nodes"; do
    # shellcheck disable=SC2086
    if [ "$(can_join ${probe})" != no ]; then
        echo "ERROR: the join token may ${probe}" >&2; exit 1
    fi
done

log "joining the worker (microshift add-node --worker, up to 10m)"
wexec microshift add-node --worker --kubeconfig /tmp/bootstrap-kubeconfig

log "assert: the join left no copy of its credential"
if wexec test -e /var/lib/microshift/bootstrap/kubeconfig; then
    echo "ERROR: add-node left its bootstrap kubeconfig on the worker" >&2; exit 1
fi
wexec rm -f /tmp/bootstrap-kubeconfig

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

# Root on a worker holds the zone pod's token. It must not be the
# controller's account: that one writes any ConfigMap, kube-system's
# kubelet-client-ca included. The status patch is the control: it proves the
# probe reads RBAC rather than failing for another reason.
log "assert: the worker's OVN account writes nothing outside its namespace"
sa=system:serviceaccount:openshift-ovn-kubernetes:ovn-kubernetes-node-limited
ds_sa="$(koc -n openshift-ovn-kubernetes get ds ovnkube-node -o jsonpath='{.spec.template.spec.serviceAccountName}')"
[ "${ds_sa}" = ovn-kubernetes-node-limited ] \
    || { echo "ERROR: ovnkube-node runs as '${ds_sa}'" >&2; exit 1; }
can() { koc auth can-i --as="${sa}" "$@" 2>/dev/null || true; }
[ "$(can patch pods --subresource=status -n default)" = yes ] \
    || { echo "ERROR: ${sa} cannot patch pod status; the probe below proves nothing" >&2; exit 1; }
for probe in "update configmaps -n kube-system" "patch pods -n default" \
        "patch nodes" "delete pods -n default"; do
    # shellcheck disable=SC2086
    if [ "$(can ${probe})" != no ]; then
        echo "ERROR: ${sa} may ${probe}" >&2; exit 1
    fi
done

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

log "assert: cross-node pod-to-pod, pod-to-service, and cluster DNS"
util_img="$(koc -n openshift-ovn-kubernetes get pods -o jsonpath='{.items[0].spec.containers[0].image}')"
koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mn-echo-ctrl
  labels: {app: mn-echo}
spec:
  nodeSelector: {kubernetes.io/hostname: ${CTRL}}
  containers:
  - name: echo
    image: ${util_img}
    command: ["/bin/bash","-c","mkdir -p /tmp/www && cd /tmp/www && echo mn-echo-ctrl > index.html && exec python3 -m http.server 8080"]
---
apiVersion: v1
kind: Pod
metadata:
  name: mn-echo-worker
  labels: {app: mn-echo}
spec:
  nodeSelector: {kubernetes.io/hostname: ${WORKER}}
  containers:
  - name: echo
    image: ${util_img}
    command: ["/bin/bash","-c","mkdir -p /tmp/www && cd /tmp/www && echo mn-echo-worker > index.html && exec python3 -m http.server 8080"]
---
apiVersion: v1
kind: Service
metadata:
  name: mn-echo
spec:
  selector: {app: mn-echo}
  ports: [{port: 80, targetPort: 8080}]
EOF
ok=false
for _ in $(seq 60); do
    if [ "$(koc get pods -l app=mn-echo --no-headers 2>/dev/null | grep -c ' Running')" -eq 2 ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: echo pods did not start on both nodes" >&2; exit 1; }
ip_c="$(koc get pod mn-echo-ctrl -o jsonpath='{.status.podIP}')"
ip_w="$(koc get pod mn-echo-worker -o jsonpath='{.status.podIP}')"
cip="$(koc get svc mn-echo -o jsonpath='{.spec.clusterIP}')"
fetch() { # fetch <pod> <url>
    koc exec "$1" -- python3 -c "import urllib.request; print(urllib.request.urlopen('$2', timeout=5).read().decode().strip())" 2>/dev/null
}
ok=false
for _ in $(seq 24); do
    if [ "$(fetch mn-echo-worker "http://${ip_c}:8080")" = "mn-echo-ctrl" ]; then ok=true; break; fi
    sleep 5
done
${ok} || { echo "ERROR: worker pod cannot reach the controller pod (pod-to-pod across geneve)" >&2; exit 1; }
[ "$(fetch mn-echo-ctrl "http://${ip_w}:8080")" = "mn-echo-worker" ] \
    || { echo "ERROR: controller pod cannot reach the worker pod" >&2; exit 1; }
fetch mn-echo-worker "http://${cip}:80" | grep -q 'mn-echo' \
    || { echo "ERROR: worker pod cannot reach the ClusterIP service" >&2; exit 1; }
koc exec mn-echo-worker -- python3 -c \
    "import socket; print(socket.getaddrinfo('kubernetes.default.svc.cluster.local', 443)[0][4][0])" \
    | grep -q '10\.43\.' || { echo "ERROR: cluster DNS does not resolve from a worker pod" >&2; exit 1; }

log "assert: worker healthcheck gates on its own readiness"
wexec microshift healthcheck -v=2 --timeout=120s

log "MULTINODE SMOKE TEST PASSED"
