#!/bin/bash
# Two-node acceptance test for the worker topology: boot two VMs of the
# image on one NAT-bridged network, keep firewalld and the role-scoped
# services in place, join the second VM with 'microshift-profile worker'
# + 'microshift add-node --worker', and assert the result is a working
# cluster: both nodes Ready, every pod Running, cross-node pod-to-pod
# and pod-to-service traffic, cluster DNS from a worker pod, a primary
# user-defined network spanning both nodes, and
# greenboot health checks green on both roles. Then the controller takes an
# update from a registry on the host and the worker must follow it.
#
# Requires root-capable podman, qemu-system-x86_64 and dnsmasq (or
# QEMU_IMAGE, scripts/lib-qemu.sh), and sudo for the bridge/taps. Runner-sized: two 5GB VMs.
#
# Usage: DIST_IMAGE=ghcr.io/epheo/microshift:latest ./scripts/multinode-test.sh
set -euo pipefail

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
WORKDIR="${WORKDIR:-/tmp/epheo-microshift-multinode}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-quay.io/libpod/registry:2.8}"
REG_NAME=epheo-microshift-multinode-registry
VM_MEM="${VM_MEM:-5120}"
BR=ushift-mn-br0
# Keep guest networks out of 10.42-10.43: pods and services live there.
NET=192.168.101
IP1=$NET.11
IP2=$NET.12
MAC1=52:54:00:45:00:01
MAC2=52:54:00:45:00:02
REG="${NET}.1:5000"
KEEP="${KEEP:-0}"
. "$(dirname "$0")/lib-diag.sh"
. "$(dirname "$0")/lib-settle.sh"
. "$(dirname "$0")/lib-qemu.sh"

log() { echo "--- $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# ssh strips a quoting layer; re-quote args (same as vm-test.sh).
nssh() { # nssh <ip> <cmd...>
    local ip=$1; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR -i "${WORKDIR}/id" \
        "root@${ip}" "$(printf '%q ' "$@")"
}
v1() { nssh "${IP1}" "$@"; }
v2() { nssh "${IP2}" "$@"; }
KCFG=/var/lib/microshift/resources/kubeadmin/kubeconfig
koc() { v1 oc --kubeconfig "${KCFG}" "$@"; }

host_net_up() {
    sudo ip link add "${BR}" type bridge 2>/dev/null || true
    sudo ip addr replace "${NET}.1/24" dev "${BR}"
    sudo ip link set "${BR}" up
    sudo sysctl -qw net.ipv4.ip_forward=1
    sudo iptables -t nat -C POSTROUTING -s "${NET}.0/24" ! -o "${BR}" -j MASQUERADE 2>/dev/null \
        || sudo iptables -t nat -A POSTROUTING -s "${NET}.0/24" ! -o "${BR}" -j MASQUERADE
    sudo iptables -C FORWARD -i "${BR}" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -i "${BR}" -j ACCEPT
    sudo iptables -C FORWARD -o "${BR}" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -o "${BR}" -j ACCEPT
    for t in tap-ushift1 tap-ushift2; do
        sudo ip tuntap add "${t}" mode tap 2>/dev/null || true
        sudo ip link set "${t}" master "${BR}" up
    done
    dnsmasq_start "${WORKDIR}/dnsmasq.pid" --interface="${BR}" --bind-interfaces --except-interface=lo \
        --dhcp-range="${NET}.10,${NET}.50,12h" \
        --dhcp-host="${MAC1},${IP1}" --dhcp-host="${MAC2},${IP2}" || die "dnsmasq failed to start"
}

host_net_down() {
    sudo kill "$(sudo cat "${WORKDIR}/dnsmasq.pid" 2>/dev/null)" 2>/dev/null || true
    for t in tap-ushift1 tap-ushift2; do sudo ip link del "${t}" 2>/dev/null || true; done
    sudo ip link del "${BR}" 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -s "${NET}.0/24" ! -o "${BR}" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "${BR}" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -o "${BR}" -j ACCEPT 2>/dev/null || true
}

# The bulk, per node: microshift plus the lib's OVS unit journals.
node_journals() { # node_journals <exec-fn> <name>
    local fn=$1 name=$2
    echo "### ${name}: journalctl -u microshift (this boot) ###"
    ${fn} journalctl -u microshift --no-pager -b 2>&1
    diag_ovs_journals "${fn}" "${name}"
    echo "### ${name}: journalctl -u firewalld (this boot) ###"
    ${fn} journalctl -u firewalld --no-pager -b 2>&1 | tail -100
    echo "### ${name}: journal tail, all units ###"
    ${fn} journalctl --no-pager -b -n 400 2>&1
}

# Short enough that both nodes' worth goes to the job log verbatim.
node_summary() { # node_summary <exec-fn> <name>
    local fn=$1 name=$2
    echo "### ${name}: bootc status ###"; ${fn} bootc status 2>&1
    echo "### ${name}: br-ex, routes, cni ###"
    ${fn} sh -c 'hostname; ip -br addr show br-ex 2>/dev/null; ovs-vsctl --timeout=5 list-ports br-ex; ls /etc/cni/net.d/ 2>/dev/null' 2>&1
    echo "### ${name}: ovs-vsctl show ###"
    ${fn} sh -c 'ovs-vsctl --timeout=5 show | head -40' 2>&1
    echo "### ${name}: failed units ###"
    ${fn} systemctl list-units --failed --no-pager 2>&1
    echo "### ${name}: update units (this boot) ###"
    ${fn} journalctl -b --no-pager -u microshift-update-publish -u microshift-update-follow \
        -u bootc-fetch-apply-updates 2>&1 | tail -30
    diag_selinux "${fn}" 20 "${name}"
}

# Two nodes' worth of journals is far too much for the job log, so the bulk goes
# to a file the workflow uploads and only the summaries are printed. A tail would
# not do: it can only ever reach the second node.
# All best-effort: a guest may be half-up, so nothing here may fail cleanup.
diagnostics() {
    local out="${WORKDIR}/diag.log" sum="${WORKDIR}/diag-summary.log"
    {
        echo "### nodes ###"; koc get nodes -o wide 2>&1
        echo "### non-running pods ###"
        koc get pods -A -o wide --no-headers 2>&1 | grep -vE 'Running|Completed'
        echo "### update image, lock and Volumes ###"
        koc -n kube-public get configmap microshift-update microshift-update-lock -o yaml 2>&1
        koc get volumes.r-drbd.io 2>&1
        echo "### events ###"
        koc get events -A --sort-by='.metadata.creationTimestamp' 2>&1 | tail -30
        echo "### not-ready pod logs ###"
        for p in $(koc get pods -A --no-headers 2>/dev/null \
                | awk '$4 !~ /Running|Completed/ {print $1"/"$2}'); do
            echo "--- ${p}"
            koc -n "${p%/*}" logs "${p#*/}" --all-containers --tail=20 </dev/null 2>&1
        done
        echo "### node2 ovnkube-node containers ###"
        p2=$(koc -n openshift-ovn-kubernetes get pods -o wide --no-headers 2>/dev/null \
            | awk '/ovnkube-node/ && $7=="node2" {print $1}')
        [ -n "${p2:-}" ] && koc -n openshift-ovn-kubernetes logs "${p2}" \
            --all-containers --tail=30 </dev/null 2>&1
        node_journals v1 node1
        node_journals v2 node2
    } > "${out}" 2>&1 || true
    { node_summary v1 node1; node_summary v2 node2; } > "${sum}" 2>&1 || true
    log "cluster state and journals written to ${out} (uploaded as an artifact)"
    log "per-node summary:"
    cat "${sum}" 2>/dev/null || true
    log "consoles (last 15 lines each)"
    sudo tail -15 "${WORKDIR}/console1.log" 2>/dev/null || true
    sudo tail -15 "${WORKDIR}/console2.log" 2>/dev/null || true
}

cleanup() {
    rc=$?
    [ ${rc} -ne 0 ] && { log "FAILED (rc=${rc})"; diagnostics; }
    if [ "${KEEP}" = 1 ]; then
        log "keeping VMs and ${WORKDIR} (ssh -i ${WORKDIR}/id root@${IP1} / ${IP2})"
        exit ${rc}
    fi
    for n in 1 2; do sudo kill "$(sudo cat "${WORKDIR}/qemu${n}.pid" 2>/dev/null)" 2>/dev/null || true; done
    sleep 1
    sudo podman rm -f "${REG_NAME}" >/dev/null 2>&1 || true
    host_net_down
    # On failure keep WORKDIR: the workflow uploads console*.log and diag*.log
    # from it AFTER this script exits, and the next run starts with its own
    # rm -rf anyway. Deleting here made every past failure artifact empty.
    [ ${rc} -eq 0 ] && sudo rm -rf "${WORKDIR}"
    exit ${rc}
}
trap cleanup EXIT

retry() { # retry <seconds> <description> <cmd...>
    local deadline=$(( $(date +%s) + $1 )) desc=$2
    echo "waiting up to $1s for: ${desc}"
    shift 2
    until "$@" >/dev/null 2>&1; do
        [ "$(date +%s)" -gt "${deadline}" ] && die "timed out waiting for: ${desc}"
        sleep 5
    done
    log "ok: ${desc}"
}

sudo rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/output"

# --- 1. Image into the root store (registry refs get pulled) -----------------
if podman image exists "${DIST_IMAGE}" 2>/dev/null; then
    rootless_id="$(podman image inspect --format '{{.Id}}' "${DIST_IMAGE}")"
    rootful_id="$(sudo podman image inspect --format '{{.Id}}' "${DIST_IMAGE}" 2>/dev/null || true)"
    if [ "${rootless_id}" != "${rootful_id}" ]; then
        log "copying ${DIST_IMAGE} from the user image store to the root store"
        podman save "${DIST_IMAGE}" | sudo podman load
    fi
elif ! sudo podman image exists "${DIST_IMAGE}"; then
    case "${DIST_IMAGE}" in
        *.*/*) log "pulling ${DIST_IMAGE}"; sudo podman pull -q "${DIST_IMAGE}" ;;
        *) die "image '${DIST_IMAGE}' not found (run 'make image' first)" ;;
    esac
fi

# bootc-image-builder resolves bare names against docker.io; a locally
# built image must be addressed as localhost/<name> (registry refs as-is).
case "${DIST_IMAGE}" in
    *.*/*) SRC_IMAGE="${DIST_IMAGE}" ;;
    *)     SRC_IMAGE="localhost/${DIST_IMAGE}:latest" ;;
esac

# --- 2. qcow2 ----------------------------------------------------------------
log "building qcow2 from ${SRC_IMAGE} (bootc-image-builder)"
ssh-keygen -q -t ed25519 -N '' -f "${WORKDIR}/id"
# The update test pulls from the host over plain HTTP and needs room for a
# second deployment.
cat > "${WORKDIR}/config.toml" <<EOF
[[customizations.user]]
name = "root"
key = "$(cat "${WORKDIR}/id.pub")"

[[customizations.files]]
path = "/etc/containers/registries.conf.d/900-multinode-test.conf"
data = "[[registry]]\nlocation = \"${REG}\"\ninsecure = true\n"

[[customizations.filesystem]]
mountpoint = "/"
minsize = "20 GiB"
EOF
sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "${WORKDIR}/config.toml:/config.toml:ro" \
    -v "${WORKDIR}/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB_IMAGE}" --type qcow2 --config /config.toml "${SRC_IMAGE}"
DISK1="${WORKDIR}/output/qcow2/disk.qcow2"
sudo test -f "${DISK1}" || die "bootc-image-builder produced no qcow2"
DISK2="${WORKDIR}/disk2.qcow2"
sudo cp --reflink=auto "${DISK1}" "${DISK2}"

# --- 3. Two VMs on the shared network ----------------------------------------
log "creating the shared NAT bridge network"
host_net_up

boot_vm() { # boot_vm <n> <disk> <mac> <tap>
    local n=$1 disk=$2 mac=$3 tap=$4
    local accel=tcg
    [ -e /dev/kvm ] && accel=kvm
    # Secondary disk: VG myvg1 with thin pool thin, which the controller
    # declares as its r-drbd Pool by itself.
    sudo truncate --size=16G "${WORKDIR}/lvm-disk${n}.raw"
    qemu_start "${WORKDIR}/qemu${n}.pid" \
        -machine "accel=${accel}" -cpu max -smp 4 -m "${VM_MEM}" \
        -drive "file=${disk},if=virtio,format=qcow2" \
        -drive "file=${WORKDIR}/lvm-disk${n}.raw,if=virtio,format=raw" \
        -netdev "tap,id=n0,ifname=${tap},script=no,downscript=no" \
        -device "virtio-net-pci,netdev=n0,mac=${mac}" \
        -device virtio-rng-pci \
        -serial "file:${WORKDIR}/console${n}.log" \
        -display none
}

log "booting two VMs"
boot_vm 1 "${DISK1}" "${MAC1}" tap-ushift1
boot_vm 2 "${DISK2}" "${MAC2}" tap-ushift2

retry 600 "node1 ssh reachable" v1 true
retry 600 "node2 ssh reachable" v2 true

log "provisioning the storage volume group and thin pool on each node"
for v in v1 v2; do
    $v vgcreate -f -y myvg1 /dev/vdb
    $v lvcreate -q -y --type thin-pool -l 90%FREE -n thin myvg1
done

# The single-node first boot must settle before reshaping either node:
# it proves the image itself and pre-imports the embedded payload.
settled() { # settled <vssh-fn>
    $1 sh -c 'k="oc --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig"; $k get pods -A --no-headers 2>/dev/null | grep -q . || exit 1; $k get pods -A --no-headers | grep -vE "Running|Completed" | grep -q . && exit 1; exit 0'
}
node1_settled() { settled v1; }
node2_settled() { settled v2; }
retry 900 "node1 first boot settled" node1_settled
retry 900 "node2 first boot settled" node2_settled

# The apiserver reaches kubelets by node name (logs, exec).
for fn in v1 v2; do
    ${fn} sh -c "printf '${IP1} node1\n${IP2} node2\n' >> /etc/hosts"
done

# --- 4. Reshape: node1 controller, node2 worker -------------------------------
# firewalld stays RUNNING throughout: the role-scoped services are part of
# what this test accepts. greenboot is stopped only around cleanup-data
# (a running health check fights the wipe) and re-asserted at the end.
node_config() { # node_config <vssh-fn> <hostname> <ip>
    local fn=$1 host=$2 ip=$3
    step() { echo "  [${host}] $1"; shift; "${fn}" "$@" || die "[${host}] failed: $*"; }
    step "pause greenboot around the wipe" sh -c 'systemctl stop greenboot-healthcheck 2>/dev/null; systemctl reset-failed greenboot-healthcheck 2>/dev/null; true'
    step "set hostname" hostnamectl set-hostname "${host}"
    step "write node config" sh -c "mkdir -p /etc/microshift/config.d && printf 'node:\n  hostnameOverride: ${host}\n  nodeIP: ${ip}\napiServer:\n  subjectAltNames:\n  - ${ip}\n' > /etc/microshift/config.d/20-multinode.yaml"
    step "wipe single-node state" sh -c 'echo 1 | microshift-cleanup-data --all --keep-images'
}

log "configuring node1 as the controller"
node_config v1 node1 "${IP1}"
v1 systemctl enable --now microshift
microshift_active() { v1 systemctl is-active -q microshift; }
retry 600 "microshift active on node1" microshift_active
node1_ready() { koc get node node1 --no-headers 2>/dev/null | grep -q ' Ready'; }
retry 600 "node1 Ready" node1_ready

log "joining node2 as a worker (microshift-profile worker + add-node --worker)"
node_config v2 node2 "${IP2}"
v2 microshift-profile worker
v2 systemctl enable microshift
v1 microshift worker-join-kubeconfig --address "${IP1}" --duration 30m > "${WORKDIR}/bootstrap-kubeconfig"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "${WORKDIR}/id" "${WORKDIR}/bootstrap-kubeconfig" "root@${IP2}:/root/bootstrap-kubeconfig"

# The join token replaces the cluster-admin kubeconfig. Creating CSRs is the
# control: it proves the probe reads RBAC rather than failing to connect.
log "assert: the join token creates CSRs and nothing an admin could"
can_join() { v2 oc --kubeconfig /root/bootstrap-kubeconfig auth can-i "$@" 2>/dev/null || true; }
[ "$(can_join create certificatesigningrequests)" = yes ] \
    || die "the join token cannot create CSRs; the probe below proves nothing"
for probe in "get secrets -n kube-system" "create pods -n default" \
        "update configmaps -n kube-system" "list nodes"; do
    # shellcheck disable=SC2086
    [ "$(can_join ${probe})" = no ] || die "the join token may ${probe}"
done

v2 microshift add-node --worker --kubeconfig /root/bootstrap-kubeconfig

log "assert: the join left no copy of its credential"
if v2 test -e /var/lib/microshift/bootstrap/kubeconfig; then
    die "add-node left its bootstrap kubeconfig on the worker"
fi
v2 rm -f /root/bootstrap-kubeconfig

# --- 5. The multinode contract ------------------------------------------------
both_ready() { [ "$(koc get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -eq 2 ]; }
retry 900 "both nodes Ready" both_ready

log "assert: node2 is a worker, not a control plane"
labels="$(koc get node node2 -o jsonpath='{.metadata.labels}')"
echo "${labels}" | grep -q 'node-role.kubernetes.io/worker' \
    || die "node2 is missing the worker role label"
if echo "${labels}" | grep -q 'node-role.kubernetes.io/control-plane'; then
    die "node2 carries the control-plane label"
fi

# v2 must succeed for the check to mean anything: a failed ssh inverted by
# the test would read as 'no key found'.
log "assert: no signing material on the worker"
v2 true
if v2 sh -c 'find /var/lib/microshift/certs -name ca.key 2>/dev/null | grep -q .'; then
    die "a CA private key is on the worker"
fi
if v2 test -f /var/lib/microshift/resources/kube-apiserver/secrets/service-account-key/service-account.key; then
    die "the service account signing key is on the worker"
fi

# Root on a worker holds the zone pod's token. It must not be the
# controller's account: that one writes any ConfigMap, kube-system's
# kubelet-client-ca included. The status patch is the control: it proves the
# probe reads RBAC rather than failing for another reason.
log "assert: the worker's OVN account writes nothing outside its namespace"
sa=system:serviceaccount:openshift-ovn-kubernetes:ovn-kubernetes-node-limited
ds_sa="$(koc -n openshift-ovn-kubernetes get ds ovnkube-node -o jsonpath='{.spec.template.spec.serviceAccountName}')"
[ "${ds_sa}" = ovn-kubernetes-node-limited ] || die "ovnkube-node runs as '${ds_sa}'"
can() { koc auth can-i --as="${sa}" "$@" 2>/dev/null || true; }
[ "$(can patch pods --subresource=status -n default)" = yes ] \
    || die "${sa} cannot patch pod status; the probe below proves nothing"
for probe in "update configmaps -n kube-system" "patch pods -n default" \
        "patch nodes" "delete pods -n default"; do
    # shellcheck disable=SC2086
    [ "$(can ${probe})" = no ] || die "${sa} may ${probe}"
done

# The approver ticks every 30s and Ready does not wait for the serving cert.
kubelet_proxied() { [ "$(koc get --raw /api/v1/nodes/node2/proxy/healthz 2>/dev/null)" = ok ]; }
retry 120 "the apiserver reaches node2's kubelet over its CSR-issued cert" kubelet_proxied

pods_settled() {
    local total
    total=$(koc get pods -A --no-headers 2>/dev/null | wc -l)
    [ "${total}" -ge 12 ] && [ -z "$(unsettled_pods)" ]
}
retry 900 "all pods Running/Completed on both nodes" pods_settled

# --- 6. Cross-node dataplane ---------------------------------------------------
log "assert: cross-node pod-to-pod, pod-to-service, and cluster DNS"
util_img="$(koc -n openshift-ovn-kubernetes get pods -o jsonpath='{.items[0].spec.containers[0].image}')"
koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mn-echo-node1
  labels: {app: mn-echo}
spec:
  nodeSelector: {kubernetes.io/hostname: node1}
  containers:
  - name: echo
    image: ${util_img}
    command: ["/bin/bash","-c","mkdir -p /tmp/www && cd /tmp/www && echo mn-echo-node1 > index.html && exec python3 -m http.server 8080"]
---
apiVersion: v1
kind: Pod
metadata:
  name: mn-echo-node2
  labels: {app: mn-echo}
spec:
  nodeSelector: {kubernetes.io/hostname: node2}
  containers:
  - name: echo
    image: ${util_img}
    command: ["/bin/bash","-c","mkdir -p /tmp/www && cd /tmp/www && echo mn-echo-node2 > index.html && exec python3 -m http.server 8080"]
---
apiVersion: v1
kind: Service
metadata:
  name: mn-echo
spec:
  selector: {app: mn-echo}
  ports: [{port: 80, targetPort: 8080}]
EOF
echo_up() { [ "$(koc get pods -l app=mn-echo --no-headers 2>/dev/null | grep -c ' Running')" -eq 2 ]; }
retry 300 "both echo pods Running" echo_up

IP_N1="$(koc get pod mn-echo-node1 -o jsonpath='{.status.podIP}')"
IP_N2="$(koc get pod mn-echo-node2 -o jsonpath='{.status.podIP}')"
CIP="$(koc get svc mn-echo -o jsonpath='{.spec.clusterIP}')"
fetch() { # fetch <pod> <url>
    koc exec "$1" -- python3 -c "import urllib.request; print(urllib.request.urlopen('$2', timeout=5).read().decode().strip())" 2>/dev/null
}
web_answers() { [ "$(fetch mn-echo-node2 "http://${IP_N1}:8080")" = "mn-echo-node1" ]; }
retry 120 "worker pod reaches controller pod (pod-to-pod across geneve)" web_answers
[ "$(fetch mn-echo-node1 "http://${IP_N2}:8080")" = "mn-echo-node2" ] \
    || die "controller pod cannot reach the worker pod"
fetch mn-echo-node2 "http://${CIP}:80" | grep -q 'mn-echo' \
    || die "worker pod cannot reach the ClusterIP service"
koc exec mn-echo-node2 -- python3 -c \
    "import socket; print(socket.getaddrinfo('kubernetes.default.svc.cluster.local', 443)[0][4][0])" \
    | grep -q '10\.43\.' || die "cluster DNS does not resolve from a worker pod"
# The endpoint behind the default kubernetes service, the controller's node
# IP, must answer from a worker pod: the shared gateway reaches it on-link.
apiserver_code="$(koc exec mn-echo-node2 -- python3 -c "
import urllib.request, urllib.error, ssl
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
try:
    urllib.request.urlopen('https://10.43.0.1:443/healthz', timeout=5, context=ctx)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
")"
echo "${apiserver_code}" | grep -qE '200|401|403' \
    || die "apiserver VIP unreachable from a worker pod (got '${apiserver_code}')"

# A primary network spans the nodes' interconnect zones (patches/0016 on
# 0008's zones), and its pods still resolve through cluster DNS.
log "assert: a primary ClusterUserDefinedNetwork spans both nodes"
koc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: mn-udn
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: mn-udn
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: mn-udn
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets: ["10.200.9.0/24"]
EOF
udn_nad() { koc -n mn-udn get network-attachment-definitions mn-udn >/dev/null 2>&1; }
retry 120 "CUDN mn-udn rendered into its namespace" udn_nad
for n in 1 2; do
    koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mn-udn-node${n}
  namespace: mn-udn
  labels: {app: mn-udn}
spec:
  nodeSelector: {kubernetes.io/hostname: node${n}}
  containers:
  - name: echo
    image: ${util_img}
    command: ["/bin/bash","-c","mkdir -p /tmp/www && cd /tmp/www && echo mn-udn-node${n} > index.html && exec python3 -m http.server 8080"]
    # Ready only if that node's kubelet gets through UDN host isolation
    # (kubelet-cgroup-path, patches/0016).
    readinessProbe:
      httpGet:
        port: 8080
      periodSeconds: 5
EOF
done
udn_up() { [ "$(koc -n mn-udn get pods -l app=mn-udn -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True)" -eq 2 ]; }
retry 300 "both primary-network pods Ready through their probes" udn_up
udn_ip_of() { koc -n mn-udn exec "$1" -- ip -o -4 addr show dev ovn-udn1 | awk '{print $4}' | cut -d/ -f1; }
UDN_N1="$(udn_ip_of mn-udn-node1)"
case "${UDN_N1}" in 10.200.9.*) ;; *) die "mn-udn-node1 has '${UDN_N1}' on ovn-udn1, want 10.200.9.x" ;; esac
udn_fetch() { # udn_fetch <pod> <url>
    koc -n mn-udn exec "$1" -- python3 -c "import urllib.request; print(urllib.request.urlopen('$2', timeout=5).read().decode().strip())" 2>/dev/null
}
udn_answers() { [ "$(udn_fetch mn-udn-node2 "http://${UDN_N1}:8080")" = "mn-udn-node1" ]; }
retry 120 "worker pod reaches controller pod on the primary network" udn_answers
koc -n mn-udn exec mn-udn-node2 -- python3 -c \
    "import socket; print(socket.getaddrinfo('kubernetes.default.svc.cluster.local', 443)[0][4][0])" \
    | grep -q '10\.43\.' || die "cluster DNS does not resolve from a worker pod on a primary network"

# --- 6b. Uniwatt's tenant shape across nodes (O6) ----------------------------
# node1 is the controller, node2 the worker. Recorded, not fatal at once: one
# run reports every case, and the section fails at its end.
uw_failed=""
uw() { local id=$1; shift; "$@" || uw_failed="${uw_failed} ${id}"; }
# mn_reach NS POD IP PORT [SOURCE]: a TCP connect from that pod, 3s timeout.
mn_reach() {
    koc -n "$1" exec "$2" -- python3 -c '
import socket, sys
src = (sys.argv[3], 0) if len(sys.argv) > 3 else None
socket.create_connection((sys.argv[1], int(sys.argv[2])), 3, src)' "$3" "$4" ${5:+"$5"} >/dev/null 2>&1
}
# mn_expect WANT NS POD IP PORT WHAT [SOURCE]: retries cover OVN programming.
mn_expect() {
    local want=$1 got
    for _ in $(seq 20); do
        if mn_reach "$2" "$3" "$4" "$5" ${7:+"$7"}; then got=yes; else got=no; fi
        [ "${got}" = "${want}" ] && return 0
        sleep 3
    done
    echo "ERROR: $2/$3 to $4:$5 reachable=${got}, want ${want} ($6)" >&2
    return 1
}
# mn_ns NAME LABEL=VALUE...: a privileged namespace with those labels.
mn_ns() {
    local name=$1 l labels=""
    shift
    for l in "$@"; do labels="${labels}    ${l%%=*}: \"${l#*=}\""$'\n'; done
    koc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${name}
  labels:
    pod-security.kubernetes.io/enforce: privileged
${labels}
EOF
}
# mn_cudn NAME ROLE SELECTOR_KEY SELECTOR_VALUE SUBNET
mn_cudn() {
    koc apply -f - >/dev/null <<EOF
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: $1
spec:
  namespaceSelector:
    matchLabels:
      $3: "$4"
  network:
    topology: Layer2
    layer2:
      role: $2
      subnets: ["$5"]
EOF
}
# mn_server NS NAME NODE [NETWORKS]: a privileged pod serving HTTP on 8080.
mn_server() {
    local nets="{}"
    [ -z "${4:-}" ] || nets="{k8s.v1.cni.cncf.io/networks: $4}"
    koc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $2
  namespace: $1
  labels: {app: $2}
  annotations: ${nets}
spec:
  nodeSelector: {kubernetes.io/hostname: $3}
  restartPolicy: Never
  containers:
  - name: server
    image: ${util_img}
    securityContext: {privileged: true}
    command: ["python3", "-m", "http.server", "8080"]
EOF
}
mn_running() { [ "$(koc -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; }
# mn_try SECONDS CMD...: retry's wait without its exit, for recorded cases.
mn_try() {
    local deadline=$(( $(date +%s) + $1 ))
    shift
    until "$@" >/dev/null 2>&1; do
        [ "$(date +%s)" -gt "${deadline}" ] && return 1
        sleep 5
    done
}
mn_wait_pods() { # mn_wait_pods NS/POD...
    local p
    for p in "$@"; do
        retry 180 "${p} Running" mn_running "${p%/*}" "${p#*/}"
    done
}
mn_if() { koc -n "$1" exec "$2" -- ip -o -4 addr show dev "$3" | awk '{print $4}' | cut -d/ -f1; }
mn_nad() { koc -n "$1" get network-attachment-definitions "$2" >/dev/null 2>&1; }

# Baseline: two projects on separate primary CUDNs, one pod per node.
log "assert: two projects on separate primary CUDNs stay isolated across nodes"
for p in p1 p2; do
    mn_ns "uw-${p}" k8s.ovn.org/primary-user-defined-network= "uw-proj=${p}"
    mn_cudn "uw-${p}" Primary uw-proj "${p}" "10.210.${p#p}.0/24"
    retry 120 "CUDN uw-${p} rendered" mn_nad "uw-${p}" "uw-${p}"
    mn_server "uw-${p}" a node1
    mn_server "uw-${p}" b node2
done
mn_wait_pods uw-p1/a uw-p1/b uw-p2/a uw-p2/b
P1B="$(mn_if uw-p1 b ovn-udn1)"
P2B="$(mn_if uw-p2 b ovn-udn1)"
uw base-same mn_expect yes uw-p1 a "${P1B}" 8080 "same project across nodes"
uw base-p1-p2 mn_expect no uw-p1 a "${P2B}" 8080 "project p1 on node1 to project p2 on node2"
uw base-p2-p1 mn_expect no uw-p2 a "${P1B}" 8080 "project p2 on node1 to project p1 on node2"
uw base-podip mn_expect no uw-p2 a "$(koc -n uw-p1 get pod b -o jsonpath='{.status.podIP}')" 8080 \
    "project p2 to project p1's status.podIP"

# Ask 3 from a worker: the API-only tier, subject on node2.
log "assert: the API-only tier on a primary network, from a worker"
for t in "${IP1} 6443" "${IP2} 10250" "${IP2} 22" "${IP1} 10250"; do
    # shellcheck disable=SC2086 # "IP PORT" splits into two arguments
    uw "worker-ctl-${t// /-}" mn_expect yes uw-p1 b ${t} "${t} from a worker's primary network, no policy"
done
koc apply -f - >/dev/null <<EOF
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: uw-api-only
spec:
  priority: 30
  subject:
    namespaces:
      matchLabels:
        kubernetes.io/metadata.name: uw-p1
  egress:
  - name: allow-api
    action: Allow
    to:
    - nodes:
        matchExpressions:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
    ports:
    - portNumber:
        protocol: TCP
        port: 6443
  - name: deny-nodes
    action: Deny
    to:
    - nodes:
        matchExpressions:
        - key: kubernetes.io/hostname
          operator: Exists
EOF
uw worker-api-svc mn_expect yes uw-p1 b kubernetes.default.svc.cluster.local 443 "the API Service from a worker under the API-only ANP"
uw worker-api-6443 mn_expect yes uw-p1 b "${IP1}" 6443 "the controller's 6443 from a worker under the API-only ANP"
for t in "${IP2} 10250" "${IP2} 22" "${IP1} 10250"; do
    # shellcheck disable=SC2086
    uw "worker-deny-${t// /-}" mn_expect no uw-p1 b ${t} "${t} from a worker under the API-only ANP"
done
# Whether the worker pod's UDN port is in the ANP's port groups on node2.
anp_diag() {
    local n2 nb
    n2="$(koc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node --field-selector spec.nodeName=node2 \
        -o jsonpath='{.items[0].metadata.name}')"
    nb=(koc -n openshift-ovn-kubernetes exec "${n2}" -c nbdb -- ovn-nbctl --no-leader-only)
    echo "== node2 port groups (name, external_ids, ports):" >&2
    "${nb[@]}" --format=csv --data=bare --no-headings --columns=name,external_ids,ports list Port_Group \
        | grep -i -e anp -e admin | cut -c1-400 >&2 || true
    echo "== node2 ports of uw-p1/b (uuid, name):" >&2
    "${nb[@]}" --format=csv --data=bare --no-headings --columns=_uuid,name list Logical_Switch_Port \
        | grep 'uw-p1_b' >&2 || true
}
case "${uw_failed}" in *worker-deny*) anp_diag ;; esac
koc delete adminnetworkpolicy uw-api-only >/dev/null

# Ask 5 across nodes: a LoadBalancer with externalTrafficPolicy Local, its one
# endpoint on node2, called from the runner on the VMs' bridge. MicroShift's
# LoadBalancer controller gives the Service the controller's node IP, node1,
# which has no endpoint: node1 either drops it or keeps the client's address,
# and which one is logged. node2's NodePort, the endpoint's own node, must
# keep it.
log "assert: externalTrafficPolicy Local keeps the client address across nodes"
koc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: lb
  namespace: uw-p1
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: b
  ports:
  - port: 30580
    targetPort: 8080
    nodePort: 30581
EOF
lb_ips() { koc -n uw-p1 get service lb -o jsonpath='{.status.loadBalancer.ingress[*].ip}'; }
lb_assigned() { [ -n "$(lb_ips)" ]; }
outside() { # outside URL: up to three tries from the runner
    local _
    for _ in 1 2 3; do curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null && return 0; sleep 5; done
    return 1
}
lb_seen() { koc -n uw-p1 logs b | awk -v p="GET /$1 " 'index($0, p) {print $1}' | sort -u | xargs; }
if mn_try 60 lb_assigned; then
    log "observe: LoadBalancer ingress: $(lb_ips) (node1 ${IP1}, node2 ${IP2})"
    for ip in $(lb_ips); do outside "http://${ip}:30580/via-lb-${ip}" || true; done
    outside "http://${IP2}:30581/via-nodeport-node2" || true
    outside "http://${IP1}:30581/via-nodeport-node1" || true
    for ip in $(lb_ips); do
        seen="$(lb_seen "via-lb-${ip}")"
        log "observe: via the LoadBalancer address ${ip}, the pod saw '${seen:-nothing: dropped}'"
        [ -z "${seen}" ] || [ "${seen}" = "${NET}.1" ] || {
            echo "ERROR: via ${ip} the pod saw '${seen}': delivered with the source rewritten" >&2
            uw_failed="${uw_failed} lb-source"; }
    done
    seen="$(lb_seen via-nodeport-node1)"
    log "observe: via node1's NodePort (no endpoint), the pod saw '${seen:-nothing: dropped}'"
    [ -z "${seen}" ] || [ "${seen}" = "${NET}.1" ] || {
        echo "ERROR: via node1's NodePort the pod saw '${seen}': delivered with the source rewritten" >&2
        uw_failed="${uw_failed} nodeport-other-source"; }
    seen="$(lb_seen via-nodeport-node2)"
    log "observe: via node2's NodePort (the endpoint's node), the pod saw '${seen}'"
    [ "${seen}" = "${NET}.1" ] || {
        echo "ERROR: via node2's NodePort the pod saw '${seen}', want the runner ${NET}.1" >&2
        uw_failed="${uw_failed} nodeport-endpoint-source"; }
else
    uw_failed="${uw_failed} lb-ingress"
fi

# Ask 6: two namespaces on one CUDN, client on node1, backend on node2; a
# NetworkPolicy admits the CUDN's namespaces under a default deny.
log "assert: a Service across namespaces on one CUDN, under a NetworkPolicy on the CUDN's label"
for ns in uw-ga uw-gb; do
    mn_ns "${ns}" k8s.ovn.org/primary-user-defined-network= uw-cudn=shared
done
mn_cudn uw-shared Primary uw-cudn shared 10.210.6.0/24
retry 120 "CUDN uw-shared rendered" mn_nad uw-gb uw-shared
mn_server uw-ga client node1
mn_server uw-gb backend node2
mn_wait_pods uw-ga/client uw-gb/backend
koc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: uw-gb
spec:
  selector:
    app: backend
  ports:
  - port: 8080
EOF
gb_svc="$(koc -n uw-gb get service backend -o jsonpath='{.spec.clusterIP}')"
uw shared-ctl mn_expect yes uw-ga client "${gb_svc}" 8080 "the other namespace's Service, no policy"
koc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: uw-gb
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-cudn
  namespace: uw-gb
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          uw-cudn: shared
EOF
uw shared-allow mn_expect yes uw-ga client "${gb_svc}" 8080 "the Service under an allow on the CUDN's label"
koc -n uw-gb delete networkpolicy allow-cudn >/dev/null
uw shared-deny mn_expect no uw-ga client "${gb_svc}" 8080 "the Service once the allow is gone"

# Asks 7, 8 and 10: one secondary Layer2 CUDN joins an edge (node1) to
# Gateway pods (node2), MultiNetworkPolicy on it, and a Gateway that is also
# on its project's primary CUDN (dual-homed).
log "assert: MultiNetworkPolicy on a secondary CUDN across nodes"
mn_ns uw-edge uw-transit=yes
mn_ns uw-gw1 uw-transit=yes
mn_ns uw-gw2 uw-transit=yes
mn_ns uw-dual k8s.ovn.org/primary-user-defined-network= uw-transit=yes uw-dualnet=yes
mn_cudn uw-transit Secondary uw-transit yes 10.220.0.0/24
mn_cudn uw-dualnet Primary uw-dualnet yes 10.230.0.0/24
for ns in uw-edge uw-gw1 uw-gw2 uw-dual; do
    retry 120 "uw-transit rendered in ${ns}" mn_nad "${ns}" uw-transit
done
retry 120 "uw-dualnet rendered in uw-dual" mn_nad uw-dual uw-dualnet
mn_server uw-edge edge node1 uw-transit
mn_server uw-gw1 gw node2 uw-transit
mn_server uw-gw2 gw node2 uw-transit
mn_server uw-dual dual node2 uw-transit
mn_server uw-dual tenant node1
mn_wait_pods uw-edge/edge uw-gw1/gw uw-gw2/gw uw-dual/dual uw-dual/tenant
EDGE_T="$(mn_if uw-edge edge net1)"
GW1_T="$(mn_if uw-gw1 gw net1)"
GW2_T="$(mn_if uw-gw2 gw net1)"
DUAL_T="$(mn_if uw-dual dual net1)"
DUAL_P="$(mn_if uw-dual dual ovn-udn1)"
log "observe: transit edge ${EDGE_T}, gw1 ${GW1_T}, gw2 ${GW2_T}, dual ${DUAL_T} (primary ${DUAL_P})"
uw mnp-ctl-gw1-gw2 mn_expect yes uw-gw1 gw "${GW2_T}" 8080 "gw1 to gw2 on transit, no policy"
uw mnp-ctl-edge-gw2 mn_expect yes uw-edge edge "${GW2_T}" 8080 "edge to gw2 on transit, no policy"
uw mnp-ctl-gw1-edge mn_expect yes uw-gw1 gw "${EDGE_T}" 8080 "gw1 to edge on transit, no policy"

# Ask 7: gw2 admits the edge's namespace only.
koc apply -f - >/dev/null <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: from-edge
  namespace: uw-gw2
  annotations:
    k8s.v1.cni.cncf.io/policy-for: uw-gw2/uw-transit
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: uw-edge
EOF
uw mnp-drop-gw1-gw2 mn_expect no uw-gw1 gw "${GW2_T}" 8080 "gw1 to gw2 under gw2's from-edge MNP"
uw mnp-admit-edge mn_expect yes uw-edge edge "${GW2_T}" 8080 "edge to gw2 under gw2's from-edge MNP"
koc -n uw-gw2 delete multi-networkpolicy from-edge >/dev/null

# Ask 7: all egress denied from gw1.
koc apply -f - >/dev/null <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: no-egress
  namespace: uw-gw1
  annotations:
    k8s.v1.cni.cncf.io/policy-for: uw-gw1/uw-transit
spec:
  podSelector: {}
  policyTypes: [Egress]
EOF
uw mnp-no-egress mn_expect no uw-gw1 gw "${EDGE_T}" 8080 "gw1 to edge under a deny-all egress MNP"
koc -n uw-gw1 delete multi-networkpolicy no-egress >/dev/null
uw mnp-no-egress-gone mn_expect yes uw-gw1 gw "${EDGE_T}" 8080 "gw1 to edge once the egress MNP is gone"

# Ask 7: the edge dials out and accepts nothing: ingress deny-all, egress to
# gw1's namespace only. Its own connections get their replies (stateful).
koc apply -f - >/dev/null <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: dial-out
  namespace: uw-edge
  annotations:
    k8s.v1.cni.cncf.io/policy-for: uw-edge/uw-transit
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: uw-gw1
EOF
uw mnp-dial-out mn_expect yes uw-edge edge "${GW1_T}" 8080 "edge dialing gw1 under its dial-out MNP"
uw mnp-dial-in mn_expect no uw-gw1 gw "${EDGE_T}" 8080 "gw1 dialing the edge under the edge's dial-out MNP"
uw mnp-dial-other mn_expect no uw-edge edge "${GW2_T}" 8080 "edge dialing gw2, outside its egress allow"
koc -n uw-edge delete multi-networkpolicy dial-out >/dev/null

# Ask 8: a tenant on the dual-homed Gateway's primary network routes the
# transit range through it, forwarding on, and the edge routes the tenant's
# range back the same way: port security drops the forwarded source, so
# nothing gets through. The dual pod reaches the edge itself.
log "assert: a dual-homed pod cannot relay its primary network into a secondary CUDN"
uw dual-ctl mn_expect yes uw-dual dual "${EDGE_T}" 8080 "the dual-homed pod to the edge on transit"
koc -n uw-dual exec dual -- sysctl -qw net.ipv4.ip_forward=1
koc -n uw-dual exec tenant -- ip route replace 10.220.0.0/24 via "${DUAL_P}"
koc -n uw-edge exec edge -- ip route replace 10.230.0.0/24 via "${DUAL_T}"
uw dual-relay mn_expect no uw-dual tenant "${EDGE_T}" 8080 "a tenant relayed through the dual-homed pod"
relayed="$(koc -n uw-edge logs edge | awk '$1 ~ /^10\.230\./ {print $1}' | sort -u | xargs)"
[ -z "${relayed}" ] || { echo "ERROR: the edge served ${relayed} from the dual pod's primary network" >&2; uw_failed="${uw_failed} dual-relay-served"; }
# The transit port pins its IP: a second address on net1 gets nowhere.
koc -n uw-edge exec edge -- ip addr add 10.220.0.250/24 dev net1
uw transit-ip-pinned mn_expect no uw-edge edge "${GW1_T}" 8080 "the edge from an address it was not given" 10.220.0.250
uw transit-ip-own mn_expect yes uw-edge edge "${GW1_T}" 8080 "the edge from its own address" "${EDGE_T}"
koc -n uw-edge exec edge -- ip addr del 10.220.0.250/24 dev net1
# And its MAC: OVN's port security on the edge's transit port names both.
edge_mac="$(koc -n uw-edge exec edge -- cat /sys/class/net/net1/address)"
n1_ovnk="$(koc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node --field-selector spec.nodeName=node1 -o jsonpath='{.items[0].metadata.name}')"
edge_ps="$(koc -n openshift-ovn-kubernetes exec "${n1_ovnk}" -c nbdb -- ovn-nbctl --no-leader-only \
    --format=csv --data=bare --no-headings --columns=name,port_security list Logical_Switch_Port 2>/dev/null \
    | grep 'uw-edge_edge' | grep -F "${EDGE_T}" || true)"
log "observe: edge transit port: ${edge_ps}"
case "${edge_ps}" in *"${edge_mac} ${EDGE_T}"*) ;; *)
    echo "ERROR: the edge's transit port does not pin ${edge_mac} ${EDGE_T}: '${edge_ps}'" >&2
    uw_failed="${uw_failed} transit-port-security" ;;
esac

# Ask 9 across nodes: portail binds its admin port on status.podIP. On a
# primary-network pod that is the default-network address; kubelet on its
# node probes it, no pod on the other node reaches it.
log "assert: status.podIP of a primary-network pod is reachable by its kubelet only"
koc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: admin
  namespace: uw-p1
  labels: {app: admin}
spec:
  nodeSelector: {kubernetes.io/hostname: node2}
  restartPolicy: Never
  containers:
  - name: admin
    image: ${util_img}
    env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    command: ["/bin/bash", "-c", "python3 -m http.server 8080 & exec python3 -m http.server 19099 --bind \"\${POD_IP}\""]
    readinessProbe:
      httpGet:
        port: 19099
      periodSeconds: 5
EOF
admin_ready() { [ "$(koc -n uw-p1 get pod admin -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; }
log "waiting up to 180s for: uw-p1/admin Ready through a probe on status.podIP:19099"
if mn_try 180 admin_ready; then
    ADMIN_POD="$(koc -n uw-p1 get pod admin -o jsonpath='{.status.podIP}')"
    ADMIN_UDN="$(mn_if uw-p1 admin ovn-udn1)"
    log "observe: uw-p1/admin status.podIP ${ADMIN_POD}, ovn-udn1 ${ADMIN_UDN}"
    case "${ADMIN_POD}" in 10.42.*) ;; *) echo "ERROR: status.podIP '${ADMIN_POD}' is not on the default network" >&2; uw_failed="${uw_failed} podip-network" ;; esac
    uw podip-ctl-cudn mn_expect yes uw-p1 a "${ADMIN_UDN}" 8080 "a same-CUDN pod on node1 to the admin pod's UDN address"
    uw podip-ctl-default mn_expect yes default mn-echo-node1 "$(koc get pod mn-echo-node2 -o jsonpath='{.status.podIP}')" 8080 \
        "a default-network pod on node1 to one on node2"
    uw podip-cudn mn_expect no uw-p1 a "${ADMIN_POD}" 19099 "a same-CUDN pod on node1 to status.podIP:19099"
    uw podip-default mn_expect no default mn-echo-node1 "${ADMIN_POD}" 19099 "a default-network pod on node1 to status.podIP:19099"
    koc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-admin
  namespace: uw-p1
spec:
  podSelector:
    matchLabels: {app: admin}
  policyTypes: [Ingress]
EOF
    uw podip-np mn_expect no uw-p1 a "${ADMIN_UDN}" 8080 "a same-CUDN pod to the admin pod under a deny-all NetworkPolicy"
    sleep 30
    admin_ready || { echo "ERROR: uw-p1/admin lost Ready under a deny-all NetworkPolicy" >&2; uw_failed="${uw_failed} probe-under-deny"; }
else
    koc -n uw-p1 describe pod admin >&2 || true
    uw_failed="${uw_failed} admin-probe"
fi

koc delete adminnetworkpolicy uw-api-only --ignore-not-found >/dev/null
koc delete namespace uw-p1 uw-p2 uw-ga uw-gb uw-edge uw-gw1 uw-gw2 uw-dual --wait=false >/dev/null
koc delete clusteruserdefinednetwork uw-p1 uw-p2 uw-shared uw-transit uw-dualnet --wait=false >/dev/null
[ -z "${uw_failed}" ] || die "Uniwatt tenant cases failed:${uw_failed}"

# --- 7. greenboot gates both roles ---------------------------------------------
# Run the packaged check scripts directly: that is exactly what greenboot
# executes, without re-arming the boot-status/rollback machinery mid-life,
# and the failing check's own output lands in the log.
log "assert: greenboot health checks pass on both nodes"
greenboot_checks() { # greenboot_checks <vssh-fn> <label>
    $1 sh -c 'rc=0; for s in /usr/lib/greenboot/check/required.d/*.sh /etc/greenboot/check/required.d/*.sh; do
        [ -e "$s" ] || continue
        echo "== $s"
        if ! "$s"; then echo "CHECK FAILED: $s"; rc=1; fi
    done; exit $rc' || die "greenboot checks red on the $2"
}
greenboot_checks v1 controller
greenboot_checks v2 worker

# --- 8. A joined worker restarts on its kubelet kubeconfig alone ---------------
log "assert: the worker restarts without the bootstrap kubeconfig"
v2 systemctl restart microshift || die "worker microshift failed to restart after the join"
retry 300 "both nodes Ready after the worker restart" both_ready
# A Ready node can still leave new pods without networking: a restart that
# reran configure-ovs cleared ovn-remote under the running ovnkube.
log "assert: a new pod on the worker gets its network after the restart"
koc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: mn-after-restart
spec:
  nodeSelector: {kubernetes.io/hostname: node2}
  containers:
  - name: probe
    image: ${util_img}
    command: ["sleep", "3600"]
EOF
after_restart_up() { koc get pod mn-after-restart --no-headers 2>/dev/null | grep -q ' Running'; }
retry 180 "a new pod Running on node2 after its restart" after_restart_up
koc delete pod mn-after-restart --wait=false >/dev/null

# --- 9. A down worker does not fail the control plane's greenboot ---------------
# Counting the worker's unavailable DaemonSet pods would turn the control
# plane red and roll it back over another machine's outage.
log "assert: the controller stays green while the worker is down"
v2 systemctl stop microshift
node2_notready() { koc get node node2 --no-headers 2>/dev/null | grep -q 'NotReady'; }
retry 300 "node2 NotReady" node2_notready
# Node NotReady comes first; the DaemonSet only counts the worker's pod as
# unavailable a moment later. Checking before that proves nothing.
ovnk_short() {
    local s
    s="$(koc -n openshift-ovn-kubernetes get ds ovnkube-node \
        -o jsonpath='{.status.numberAvailable}/{.status.desiredNumberScheduled}')"
    [ "${s%/*}" -lt "${s#*/}" ]
}
retry 300 "ovnkube-node counts the worker's pod unavailable" ovnk_short
greenboot_checks v1 controller
v2 systemctl start microshift
retry 300 "both nodes Ready after the worker comes back" both_ready

# --- 10. The worker follows the controller's update -----------------------------
log "serving updates from ${REG}"
sudo podman rm -f "${REG_NAME}" >/dev/null 2>&1 || true
sudo podman run -d --name "${REG_NAME}" -p "${REG}:5000" "${REGISTRY_IMAGE}" >/dev/null

# push_update <tag> <marker>: the image plus one file, so a new digest.
push_update() {
    local ctx="${WORKDIR}/update-$2"
    mkdir -p "${ctx}"
    echo "$2" > "${ctx}/marker"
    printf 'FROM %s\nCOPY marker /usr/share/epheo-multinode-test\n' "${SRC_IMAGE}" > "${ctx}/Containerfile"
    sudo podman build -q -t "${REG}/epheo-microshift:$1" "${ctx}" >/dev/null
    for i in $(seq 5); do
        sudo podman push -q --tls-verify=false --digestfile "${ctx}/digest" \
            "${REG}/epheo-microshift:$1" && break
        [ "${i}" = 5 ] && die "could not push to ${REG}"
        sleep 2
    done
    cat "${ctx}/digest"
}
digest_of() { $1 bootc status --json | jq -r '.status.booted.image.imageDigest'; }
staged_of() { $1 bootc status --json | jq -r '.status.staged | "\(.image.imageDigest) \(.downloadOnly)"'; }
boot_id() { $1 cat /proc/sys/kernel/random/boot_id; }
# An unreachable node reads as no boot id, not as a new one.
rebooted() { local b; b="$(boot_id "$1")" && [ -n "${b}" ] && [ "${b}" != "$2" ]; }
lock_holder() { koc -n kube-public get configmap microshift-update-lock -o jsonpath='{.data.holder}'; }
lock_as() { # lock_as <holder>: a fresh hold, as a node mid-update leaves it
    koc -n kube-public patch configmap microshift-update-lock --type merge -p \
        "{\"data\":{\"holder\":\"$1\",\"expires\":\"$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null
}
unlock_all() {
    koc -n kube-public patch configmap microshift-update-lock --type merge \
        -p '{"data":{"holder":null,"expires":null}}' >/dev/null
}

# Another node holds the update lock from the start: the worker must wait
# for it however long the controller's own update takes.
lock_as vm-test
update_a="$(push_update update a)"
log "updating the controller to ${update_a}"
boot1="$(boot_id v1)"
v1 bootc switch --quiet "${REG}/epheo-microshift:update"
v1 systemctl reboot || true
retry 600 "node1 back from its update" rebooted v1 "${boot1}"
retry 600 "microshift active on node1" microshift_active
published() {
    [ "$(koc -n kube-public get configmap microshift-update -o jsonpath='{.data.image}')" \
        = "${REG}/epheo-microshift@${update_a}" ]
}
retry 900 "node1 green and publishing its image" published

log "assert: the worker waits while another node holds the update lock"
worker_before="$(digest_of v2)"
v2 systemctl start microshift-update-follow.service
v2 journalctl -u microshift-update-follow -b --no-pager | grep 'vm-test is updating' >/dev/null \
    || die "the worker's follow did not wait for the lock holder"
[ "$(digest_of v2)" = "${worker_before}" ] || die "the worker updated while another node held the lock"
[ "$(staged_of v2)" = "${update_a} true" ] \
    || die "the worker did not download ${update_a} while it waited (staged: $(staged_of v2))"
unlock_all

log "assert: the worker follows the controller to the same digest"
followed() { [ "$(digest_of v2)" = "${update_a}" ]; }
retry 1200 "node2 on ${update_a}" followed
retry 900 "both nodes Ready after the worker's update" both_ready
retry 900 "all pods Running/Completed after the worker's update" pods_settled
worker_green() { v2 grub2-editenv list | grep -q 'boot_success=1'; }
retry 600 "greenboot green on node2's new boot" worker_green
lock_free() { [ -z "$(lock_holder)" ]; }
# At boot, not on the next timer run, which may come 6 minutes later.
[ "$(v2 systemctl is-enabled microshift-update-follow.service)" = enabled ] \
    || die "the follow does not run at boot"
retry 120 "node2 releases the update lock after its green boot" lock_free

log "assert: bootc's own update timer stays idle on the worker"
v2 systemctl start bootc-fetch-apply-updates.service
# Not grep -q: its early exit would fail the pipe (pipefail).
v2 journalctl -u bootc-fetch-apply-updates -b --no-pager \
    | grep 'workers follow the controller' >/dev/null \
    || die "the worker's bootc-fetch-apply-updates was not skipped"

# Else the controller's timer would bring a rolled-back image back, red again.
log "assert: the controller skips an image greenboot rolled back"
update_b="$(push_update update b)"
v1 sh -c "mkdir -p /var/lib/microshift-update && echo ${update_b} >> /var/lib/microshift-update/rolled-back"
v1 systemctl start bootc-fetch-apply-updates.service
[ "$(v1 bootc status --json | jq -r '.status.staged')" = null ] \
    || die "the controller staged an image it rolled back before"
v1 journalctl -u bootc-fetch-apply-updates -b --no-pager | grep "skipping ${update_b}" >/dev/null \
    || die "the controller's update gate did not name ${update_b}"
v1 sh -c 'echo sha256:0000 > /var/lib/microshift-update/rolled-back'
log "assert: the gate lets another image through, announces it and takes the update lock for it"
v1 /usr/libexec/microshift-update gate || die "the update gate skips an image nobody rolled back"
[ "$(lock_holder)" = node1 ] || die "the gate passed without taking the update lock (holder: '$(lock_holder)')"
next="$(koc -n kube-public get configmap microshift-update -o jsonpath='{.data.next}')"
[ "${next}" = "${REG}/epheo-microshift@${update_b}" ] || die "the gate announced '${next}', not ${update_b}"

# A staged image would otherwise apply at any reboot, ahead of the lock.
log "assert: the worker downloads the announced image ahead, and a reboot does not apply it"
v2 systemctl start microshift-update-follow.service
[ "$(staged_of v2)" = "${update_b} true" ] \
    || die "the worker did not download ${update_b} ahead (staged: $(staged_of v2))"
boot2="$(boot_id v2)"
v2 systemctl reboot || true
retry 600 "node2 back from a plain reboot" rebooted v2 "${boot2}"
[ "$(digest_of v2)" = "${update_a}" ] || die "a plain reboot applied the image node2 downloaded ahead"
unlock_all
v1 rm -f /var/lib/microshift-update/rolled-back

log "MULTINODE TEST PASSED"
