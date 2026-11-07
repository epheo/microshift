#!/bin/bash
# Two-node acceptance test for the worker topology: boot two VMs of the
# image on one NAT-bridged network, keep firewalld and the role-scoped
# services in place, join the second VM with 'microshift-profile worker'
# + 'microshift add-node --worker', and assert the result is a working
# cluster: both nodes Ready, every pod Running, cross-node pod-to-pod
# and pod-to-service traffic, cluster DNS from a worker pod, and
# greenboot health checks green on both roles. Then the controller takes an
# update from a registry on the host and the worker must follow it.
#
# Requires root-capable podman, qemu-system-x86_64, dnsmasq, and sudo
# for the bridge/taps. Runner-sized: two 5GB VMs.
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
# Keep guest networks out of 10.42-10.44: pods, services, and the
# apiserver advertise address (10.44.0.0 on br-ex) live there.
NET=192.168.101
IP1=$NET.11
IP2=$NET.12
MAC1=52:54:00:45:00:01
MAC2=52:54:00:45:00:02
REG="${NET}.1:5000"
KEEP="${KEEP:-0}"
. "$(dirname "$0")/lib-diag.sh"

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
    sudo dnsmasq --interface="${BR}" --bind-interfaces --except-interface=lo \
        --dhcp-range="${NET}.10,${NET}.50,12h" \
        --dhcp-host="${MAC1},${IP1}" --dhcp-host="${MAC2},${IP2}" \
        --pid-file="${WORKDIR}/dnsmasq.pid" || die "dnsmasq failed to start"
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
}

# Short enough that both nodes' worth goes to the job log verbatim.
node_summary() { # node_summary <exec-fn> <name>
    local fn=$1 name=$2
    echo "### ${name}: bootc status ###"; ${fn} bootc status 2>&1
    echo "### ${name}: br-ex, routes, cni ###"
    ${fn} sh -c 'hostname; ip -br addr show br-ex 2>/dev/null; ip route show 10.44.0.0/32; ls /etc/cni/net.d/ 2>/dev/null' 2>&1
    echo "### ${name}: ovs-vsctl show ###"
    ${fn} sh -c 'ovs-vsctl --timeout=5 show | head -40' 2>&1
    echo "### ${name}: failed units ###"
    ${fn} systemctl list-units --failed --no-pager 2>&1
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
    sudo qemu-system-x86_64 \
        -machine "accel=${accel}" -cpu max -smp 4 -m "${VM_MEM}" \
        -drive "file=${disk},if=virtio,format=qcow2" \
        -drive "file=${WORKDIR}/lvm-disk${n}.raw,if=virtio,format=raw" \
        -netdev "tap,id=n0,ifname=${tap},script=no,downscript=no" \
        -device "virtio-net-pci,netdev=n0,mac=${mac}" \
        -device virtio-rng-pci \
        -serial "file:${WORKDIR}/console${n}.log" \
        -display none -daemonize -pidfile "${WORKDIR}/qemu${n}.pid"
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

pods_settled() {
    local total bad
    total=$(koc get pods -A --no-headers 2>/dev/null | wc -l)
    bad=$(koc get pods -A --no-headers 2>/dev/null | grep -cvE 'Running|Completed' || true)
    [ "${total}" -ge 12 ] && [ "${bad}" -eq 0 ]
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
# The endpoint behind the default kubernetes service must answer from a
# worker pod: this is the route-to-advertise-address path (patches/0008).
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
lock_holder() { koc -n kube-public get lease microshift-update -o jsonpath='{.spec.holderIdentity}'; }
lock_as() { # lock_as <holder>: a fresh hold, as a node mid-update leaves it
    koc -n kube-public patch lease microshift-update --type merge -p \
        "{\"spec\":{\"holderIdentity\":\"$1\",\"leaseDurationSeconds\":3600,\"renewTime\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)\"}}" >/dev/null
}
unlock_all() {
    koc -n kube-public patch lease microshift-update --type json \
        -p '[{"op":"remove","path":"/spec/holderIdentity"}]' >/dev/null
}

# Another node holds the update lock from the start: the worker must wait
# for it however long the controller's own update takes.
lock_as vm-test
update_a="$(push_update update a)"
log "updating the controller to ${update_a}"
boot1="$(v1 cat /proc/sys/kernel/random/boot_id)"
v1 bootc switch --quiet "${REG}/epheo-microshift:update"
v1 systemctl reboot || true
node1_rebooted() { [ "$(v1 cat /proc/sys/kernel/random/boot_id)" != "${boot1}" ]; }
retry 600 "node1 back from its update" node1_rebooted
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
unlock_all

log "assert: the worker follows the controller to the same digest"
followed() { [ "$(digest_of v2)" = "${update_a}" ]; }
retry 1200 "node2 on ${update_a}" followed
retry 900 "both nodes Ready after the worker's update" both_ready
retry 900 "all pods Running/Completed after the worker's update" pods_settled
worker_green() { v2 grub2-editenv list | grep -q 'boot_success=1'; }
retry 600 "greenboot green on node2's new boot" worker_green
lock_free() { [ -z "$(lock_holder)" ]; }
retry 600 "node2 releases the update lock after its green boot" lock_free

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
log "assert: the gate lets another image through and takes the update lock for it"
v1 /usr/libexec/microshift-update gate || die "the update gate skips an image nobody rolled back"
[ "$(lock_holder)" = node1 ] || die "the gate passed without taking the update lock (holder: '$(lock_holder)')"
unlock_all
v1 rm -f /var/lib/microshift-update/rolled-back

log "MULTINODE TEST PASSED"
