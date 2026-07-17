#!/bin/bash
# The canonical acceptance test: turn the bootc image into a qcow2 disk with
# bootc-image-builder, boot it as a real VM under QEMU/KVM, and assert the
# distribution's opinions on a genuine boot — bootloader, ostree deployment,
# systemd boot order, and greenboot actually gating the boot. This is what
# `make smoke` (privileged container, fast local iteration) cannot validate.
# The opinion assertions are functional, not existence checks: a PVC is
# provisioned and written, an OVN-K layer2 secondary network is attached,
# and the embedded portail image is started with pull policy Never.
#
# With UPGRADE_FROM set, the same suite runs on an upgraded system instead
# of a fresh install: boot a qcow2 built from the previously published
# image, bootc switch to the freshly built candidate (served from a
# throwaway local registry over the QEMU user network), reboot, then
# assert. This is the path every existing install takes on a publish;
# switch to a local ref stands in for the bootc upgrade users run, because
# the candidate is by definition not on ghcr yet. Exits 0 without testing
# when UPGRADE_FROM does not exist (first release, forks).
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
WORKDIR="${WORKDIR:-/tmp/epheo-microshift-vm${UPGRADE_FROM:+-upgrade}}"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEM="${VM_MEM:-8192}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-quay.io/libpod/registry:2.8}"
REG_PORT="${REG_PORT:-5000}"
REG_NAME=epheo-microshift-upgrade-registry
# 10.0.2.2 is the QEMU user-network alias for the host loopback.
CANDIDATE_REF="10.0.2.2:${REG_PORT}/epheo-microshift:candidate"
VG_NAME="myvg1" # must match the device-class in the packaged lvmd config

log() { echo "--- $*"; }

QEMU_PID=""
cleanup() {
    rc=$?
    [ -n "${QEMU_PID}" ] && sudo kill "${QEMU_PID}" 2>/dev/null || true
    [ -n "${UPGRADE_FROM}" ] && sudo podman rm -f "${REG_NAME}" 2>/dev/null || true
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

KCFG=/var/lib/microshift/resources/kubeadmin/kubeconfig
koc() { vssh oc --kubeconfig "${KCFG}" "$@"; }

wait_ssh() {
    log "waiting for ssh (up to 10m)"
    for _ in $(seq 120); do
        if vssh true 2>/dev/null; then return 0; fi
        sleep 5
    done
    echo "ERROR: VM never became reachable over ssh" >&2
    return 1
}

wait_microshift() {
    log "waiting for microshift.service (up to 5m)"
    for _ in $(seq 60); do
        if vssh systemctl is-active -q microshift.service 2>/dev/null; then return 0; fi
        sleep 5
    done
    echo "ERROR: microshift.service did not become active" >&2
    return 1
}

wait_node_ready() {
    log "waiting for the node to be Ready (up to 5m)"
    for _ in $(seq 60); do
        if koc get node 2>/dev/null | grep -q ' Ready '; then return 0; fi
        sleep 5
    done
    echo "ERROR: node never became Ready" >&2
    return 1
}

wait_pod_running() {
    local pod=$1 phase=""
    for _ in $(seq 60); do
        phase="$(koc get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [ "${phase}" = "Running" ] && return 0
        sleep 5
    done
    echo "ERROR: pod ${pod} never became Running (phase=${phase})" >&2
    koc describe pod "${pod}" >&2 || true
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

# The recommended site shape (see the Containerfile header): the router is
# replaced by the site's own edge. Baked in before first boot so the standard
# greenboot gate below — not bespoke assertions — is what validates it
# (regression cover for patches 0003 and 0005).
[[customizations.directories]]
path = "/etc/microshift/config.d"

[[customizations.files]]
path = "/etc/microshift/config.d/10-ingress-removed.yaml"
data = "ingress:\n  status: Removed\n"
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
        if grep -qiE 'manifest unknown|name unknown|not found|denied' "${pull_err}"; then
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
log "booting VM (accel=${ACCEL}) with a secondary disk for the TopoLVM VG"
# The packaged lvmd device-class reserves spare-gb 10; the VG must exceed
# that plus the PVC probe or TopoLVM reports zero allocatable capacity.
sudo truncate --size=16G "${WORKDIR}/lvm-disk.raw"
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

wait_ssh

log "provisioning the TopoLVM volume group on the secondary disk"
vssh vgcreate -f -y "${VG_NAME}" /dev/vdb

# --- 4b. Upgrade mode: switch to the candidate and reboot ---------------------
if [ -n "${UPGRADE_FROM}" ]; then
    log "assert: booted the previous release via bootc"
    vssh bootc status | grep -qF "${UPGRADE_FROM}"

    # No green gate on the old boot: an old release's own bugs must not be
    # able to fail the candidate's gate. The API is enough for the marker.
    wait_microshift
    wait_node_ready

    log "planting upgrade survival markers (one file on /var, one etcd object)"
    vssh sh -c 'echo pre-upgrade > /var/upgrade-marker'
    koc create configmap upgrade-marker --from-literal=probe=pre-upgrade

    log "bootc switch to the candidate (pull over the user network)"
    vssh bootc switch "${CANDIDATE_REF}"
    vssh bootc status | grep -qF "${CANDIDATE_REF}"

    log "rebooting into the candidate"
    old_boot_id="$(vssh cat /proc/sys/kernel/random/boot_id)"
    vssh reboot || true
    log "waiting for the VM to come back (up to 10m)"
    ok=false
    for _ in $(seq 120); do
        sleep 5
        boot_id="$(vssh cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        if [ -n "${boot_id}" ] && [ "${boot_id}" != "${old_boot_id}" ]; then ok=true; break; fi
    done
    ${ok} || { echo "ERROR: VM did not come back after the upgrade reboot" >&2; exit 1; }
fi

# --- 5. Assert this is a real bootc deployment of the candidate ---------------
if [ -n "${UPGRADE_FROM}" ]; then
    # Precise booted-deployment check: after a greenboot rollback the
    # candidate ref still appears in the deployment list, so a substring
    # grep over the whole status would pass wrongly.
    log "assert: the booted deployment is the candidate"
    booted="$(vssh bootc status --json | jq -r '.status.booted.image.image.image')"
    if [ "${booted}" != "${CANDIDATE_REF}" ]; then
        echo "ERROR: booted image is '${booted}', expected '${CANDIDATE_REF}' (greenboot rollback?)" >&2
        exit 1
    fi
else
    log "assert: booted via bootc from ${DIST_IMAGE}"
    vssh bootc status | grep -q "${DIST_IMAGE}"
fi

wait_microshift
wait_node_ready

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

# Functional probes reuse an image already on the node (the OVN-K image):
# no extra registry pull, no docker.io rate limits.
util_img="$(koc -n openshift-ovn-kubernetes get pods -o jsonpath='{.items[0].spec.containers[0].image}')"

# The PVC mutating webhook has failurePolicy Fail, and the controller pod
# can be Running before its webhook endpoint is Ready; applying early gets
# "no endpoints available for service topolvm-controller".
log "waiting for the TopoLVM webhook endpoints (up to 3m)"
ok=false
for _ in $(seq 36); do
    ep="$(koc -n topolvm-system get endpoints topolvm-controller -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [ -n "${ep}" ]; then ok=true; break; fi
    sleep 5
done
${ok} || {
    echo "ERROR: topolvm-controller webhook endpoints never appeared" >&2
    koc -n topolvm-system get pods >&2 || true
    exit 1
}

log "assert: TopoLVM provisions and mounts a PVC (write + read back)"
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
  storageClassName: topolvm-provisioner
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

if [ -n "${UPGRADE_FROM}" ]; then
    log "assert: data survived the upgrade (/var file + etcd object)"
    vssh cat /var/upgrade-marker | grep -q pre-upgrade
    koc get configmap upgrade-marker -o jsonpath='{.data.probe}' | grep -q pre-upgrade
fi

# The log phrasing differs between greenboot implementations (bash: "Boot
# Status is GREEN"; the CS10 Rust rewrite: "greenboot health-check passed") —
# accept both, then assert the actual contract: boot_success=1 in grubenv.
# -b: with a persistent journal a pre-upgrade GREEN would satisfy the grep.
log "assert: greenboot health checks passed (up to 5m)"
ok=false
for _ in $(seq 60); do
    if vssh journalctl -b -u greenboot-healthcheck --no-pager 2>/dev/null \
            | grep -qiE 'Status is GREEN|health-check passed'; then
        ok=true; break
    fi
    sleep 5
done
${ok} || {
    echo "ERROR: greenboot health checks did not pass" >&2
    vssh journalctl -b -u greenboot-healthcheck --no-pager | tail -30 || true
    exit 1
}

log "assert: grubenv records boot_success=1"
vssh grub2-editenv list | grep -q 'boot_success=1'

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
# greps: wording changes across the auto-bumped z-streams.
log "assert: journal is quiet at steady state (2m window)"
sleep 120
lines="$(vssh journalctl --since=-2min --no-pager | wc -l)"
[ "${lines}" -lt 500 ] || {
    echo "ERROR: ${lines} journal lines in 2m, log noise regression?" >&2
    vssh journalctl --since=-2min --no-pager | tail -40 || true
    exit 1
}

log "VM ${UPGRADE_FROM:+UPGRADE }TEST PASSED"
