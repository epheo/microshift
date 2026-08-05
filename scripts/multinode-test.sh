#!/bin/bash
# Two-node multinode acceptance test: boot two VMs of the image on one
# NAT-bridged network (the same shape as docs/contributor/multinode in
# upstream microshift, which uses libvirt's default network), join them
# with the upstream flow (microshift run --multinode on the primary,
# microshift add-node on the secondary), and assert the joined node is
# a full citizen: Ready, every pod Running, and a pod scheduled there
# reaches the apiserver service VIP through CNI.
#
# KNOWN RED as of 2026-08-05: the joined node's ovnkube-node never
# writes /etc/cni/net.d/10-ovn-kubernetes.conf, so nothing scheduled
# there gets networking. See MULTINODE-INVESTIGATION.md. This harness
# exists to make that bug reproducible in CI and to gate the fix.
#
# Requires root-capable podman, qemu-system-x86_64, dnsmasq, and sudo
# for the bridge/taps. Runner-sized: two 5GB VMs.
#
# Usage: DIST_IMAGE=ghcr.io/epheo/microshift:latest ./scripts/multinode-test.sh
set -euo pipefail

DIST_IMAGE="${DIST_IMAGE:-epheo-microshift}"
WORKDIR="${WORKDIR:-/tmp/epheo-microshift-multinode}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
VM_MEM="${VM_MEM:-5120}"
BR=ushift-mn-br0
# Keep guest networks out of 10.42-10.44: pods, services, and the
# apiserver advertise address (10.44.0.0 on br-ex) live there.
NET=192.168.101
IP1=$NET.11
IP2=$NET.12
MAC1=52:54:00:45:00:01
MAC2=52:54:00:45:00:02
KEEP="${KEEP:-0}"

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

diagnostics() {
    log "DIAGNOSTICS: nodes, non-running pods"
    koc get nodes -o wide 2>&1 || true
    koc get pods -A --no-headers 2>&1 | grep -vE 'Running|Completed' || true
    log "DIAGNOSTICS: not-running pod events"
    for p in $(koc get pods -A --no-headers 2>/dev/null \
            | awk '$4 !~ /Running|Completed/ {print $1"/"$2}'); do
        echo "--- ${p}"
        koc -n "${p%/*}" describe pod "${p#*/}" 2>&1 | sed -n '/Events:/,$p' | tail -8 || true
    done
    log "DIAGNOSTICS: kubernetes endpoints and per-node CNI/br-ex"
    koc get endpoints kubernetes 2>&1 || true
    for fn in v1 v2; do
        ${fn} sh -c 'hostname; ip -br addr show br-ex 2>/dev/null; ls /etc/cni/net.d/ 2>/dev/null; ss -ltn | grep 6443 || echo "no local 6443"' 2>&1 || true
    done
    log "DIAGNOSTICS: node2 ovnkube-node containers (raw tails)"
    p2=$(koc -n openshift-ovn-kubernetes get pods -o wide --no-headers 2>/dev/null | awk '/ovnkube-node/ && $7=="node2" {print $1}')
    [ -n "${p2:-}" ] && koc -n openshift-ovn-kubernetes logs "${p2}" --all-containers --tail=30 2>&1 | tail -40 || true
    log "DIAGNOSTICS: node2 microshift journal errors"
    v2 sh -c 'journalctl -u microshift --no-pager -p err -n 20' 2>&1 || true
    log "DIAGNOSTICS: consoles (last 15 lines each)"
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
    host_net_down
    sudo rm -rf "${WORKDIR}"
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

# --- 2. qcow2 ----------------------------------------------------------------
log "building qcow2 from ${DIST_IMAGE} (bootc-image-builder)"
ssh-keygen -q -t ed25519 -N '' -f "${WORKDIR}/id"
cat > "${WORKDIR}/config.toml" <<EOF
[[customizations.user]]
name = "root"
key = "$(cat "${WORKDIR}/id.pub")"
EOF
sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "${WORKDIR}/config.toml:/config.toml:ro" \
    -v "${WORKDIR}/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB_IMAGE}" --type qcow2 --config /config.toml "${DIST_IMAGE}"
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
    sudo qemu-system-x86_64 \
        -machine "accel=${accel}" -cpu max -smp 4 -m "${VM_MEM}" \
        -drive "file=${disk},if=virtio,format=qcow2" \
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

# First boot pulls the release images; cleanup keeps them local.
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

# --- 4. Multinode join (upstream scripts/multinode/configure-node.sh) --------
node_config() { # node_config <vssh-fn> <hostname> <ip>
    local fn=$1 host=$2 ip=$3
    step() { echo "  [${host}] $1"; shift; "${fn}" "$@" || die "[${host}] failed: $*"; }
    step "stop greenboot" sh -c 'systemctl stop greenboot-healthcheck 2>/dev/null; systemctl reset-failed greenboot-healthcheck 2>/dev/null; systemctl disable greenboot-healthcheck 2>/dev/null; true'
    step "stop firewalld" sh -c 'systemctl stop firewalld 2>/dev/null; systemctl disable firewalld 2>/dev/null; true'
    step "set hostname" hostnamectl set-hostname "${host}"
    step "write multinode config" sh -c "mkdir -p /etc/microshift/config.d && printf 'node:\n  hostnameOverride: ${host}\n  nodeIP: ${ip}\napiServer:\n  subjectAltNames:\n  - ${ip}\n' > /etc/microshift/config.d/20-multinode.yaml"
    step "wipe single-node state" sh -c 'echo 1 | microshift-cleanup-data --all --keep-images'
    step "multinode unit override" sh -c 'mkdir -p /etc/systemd/system/microshift.service.d && printf "[Service]\nExecStart=\nExecStart=microshift run --multinode\n" > /etc/systemd/system/microshift.service.d/multinode.conf'
    step "daemon-reload" systemctl daemon-reload
}

log "configuring node1 as the multinode primary"
node_config v1 node1 "${IP1}"
v1 systemctl enable --now microshift
microshift_active() { v1 systemctl is-active -q microshift; }
retry 600 "microshift active on node1" microshift_active
node1_ready() { koc get node node1 --no-headers 2>/dev/null | grep -q ' Ready'; }
retry 600 "node1 Ready" node1_ready

log "joining node2 via microshift add-node"
node_config v2 node2 "${IP2}"
BOOTSTRAP="/var/lib/microshift/resources/kubeadmin/${IP1}/kubeconfig"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "${WORKDIR}/id" "root@${IP1}:${BOOTSTRAP}" "${WORKDIR}/bootstrap-kubeconfig"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "${WORKDIR}/id" "${WORKDIR}/bootstrap-kubeconfig" "root@${IP2}:/root/bootstrap-kubeconfig"
v2 microshift add-node --kubeconfig /root/bootstrap-kubeconfig

# --- 5. The multinode contract ------------------------------------------------
both_ready() { [ "$(koc get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -eq 2 ]; }
retry 900 "both nodes Ready" both_ready

# The gate that is red today: every pod on BOTH nodes must run; the
# joined node's dns-default (daemonset) is the canary.
pods_settled() {
    local total bad
    total=$(koc get pods -A --no-headers 2>/dev/null | wc -l)
    bad=$(koc get pods -A --no-headers 2>/dev/null | grep -cvE 'Running|Completed' || true)
    [ "${total}" -ge 12 ] && [ "${bad}" -eq 0 ]
}
retry 900 "all pods Running/Completed on both nodes" pods_settled

log "assert: a pod scheduled on node2 reaches the apiserver VIP via CNI"
util_img="$(koc -n openshift-ovn-kubernetes get pods -o jsonpath='{.items[0].spec.containers[0].image}')"
koc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mn-probe
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: node2
  containers:
    - name: probe
      image: ${util_img}
      command: ["sleep", "3600"]
EOF
probe_up() { koc get pod mn-probe -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; }
retry 300 "probe pod Running on node2" probe_up
# Any HTTP status proves CNI + service VIP + cross-node path; 401/403
# is the expected unauthenticated answer.
koc exec mn-probe -- curl -ksm5 -o /dev/null -w '%{http_code}' https://10.43.0.1:443/healthz \
    | grep -qE '200|401|403' || die "apiserver VIP unreachable from a node2 pod"

log "MULTINODE TEST PASSED"
