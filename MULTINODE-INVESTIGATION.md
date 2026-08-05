# Multinode join: CNI never comes up on the joined node

Working notes for fixing multinode in this distro. Written 2026-08-05
from ten runs of stornas's two-VM replication test
(github.com/epheo/stornas, hack/replication-test.sh, workflow
`replication-test`). Reproduce here with `make multinode-test`
(scripts/multinode-test.sh, workflow `multinode`). Delete this file
when the fix lands.

## Build under test

- Image: ghcr.io/epheo/microshift:latest + stornas layer.
- RPMs inside: microshift-4.22.7_202607240848.p0_g47f0f6a9_4.22.0_okd_scos.7
  on CentOS Stream 10, kernel 6.12.0-251.el10, cri-o 1.35.5, k8s v1.35.6.
- Upstream ref train: openshift/microshift ART tags (versions.env).

## Join flow used (upstream scripts/multinode/configure-node.sh shape)

Two QEMU VMs on ONE NAT-bridged network (192.168.100.11/.12), which is
exactly the topology upstream docs/contributor/multinode/setup.md uses
(libvirt default network there). Per node:

1. stop + disable greenboot-healthcheck (upstream does; cleanup-data
   fights a running check)
2. stop + disable firewalld (upstream does)
3. hostnamectl set-hostname node1|node2
4. /etc/microshift/config.d/20-multinode.yaml:
   node.hostnameOverride, node.nodeIP, apiServer.subjectAltNames=[ip]
5. echo 1 | microshift-cleanup-data --all --keep-images
6. unit override: ExecStart=microshift run --multinode
7. primary: systemctl enable --now microshift
   secondary: microshift add-node --kubeconfig <bootstrap from
   /var/lib/microshift/resources/kubeadmin/<ip>/kubeconfig on node1>
8. cross /etc/hosts entries for node1/node2 (apiserver reaches kubelets
   by node name for logs/exec)

## What works

- add-node succeeds: etcd cluster forms
  ("initial cluster: node2=https://...:2380,node1=https://...:2380").
- Both nodes go Ready (roles control-plane,master,worker on both).
- All node1 pods run. LINSTOR controller + node1 satellite run.

## The failure

Every pod scheduled on node2 stays ContainerCreating/Init forever.
Multus events on node2:

    still waiting for readinessindicatorfile @
    /etc/cni/net.d/10-ovn-kubernetes.conf

node1 has 10-ovn-kubernetes.conf; node2 never gets one: ovnkube-node
on node2 never finishes initialization. In an earlier (pre-hosts-fix)
run its symptom was multus timing out against the apiserver VIP:

    Get "https://10.43.0.1:443/api/...": context deadline exceeded

## Hard evidence collected

1. kubernetes service endpoint in the multinode cluster is the
   single-node advertise address:
       kubernetes   10.44.0.0:6443
   and BOTH nodes carry 10.44.0.0/32 on br-ex (microshift's default
   advertiseAddress = first subnet after serviceNetwork, added to
   br-ex on every node). Any node2 client of the VIP resolves to
   10.44.0.0 and is delivered to node2's OWN br-ex. That only works
   if node2 runs a local apiserver serving :6443. Whether it does is
   the open question (run 30980996686 checks ss/curl on node2).
2. Two ovnkube-master pods exist (one per node; per-node OVN NB/SB
   databases, i.e. interconnect-style layout). Lease
   openshift-ovn-kubernetes/ovn-kubernetes-master is held by node1;
   node2's master loops "Failed to acquire lease" (standby).
3. node1's northd warns:
       No path for static route 10.42.1.0/24 on router
       ovn_cluster_router; next hop 10.42.1.2
   10.42.1.0/24 is node2's allocated node subnet: allocation happened,
   but node1's zone has no route/interconnect to it.
4. node2's ovnkube-node (container ovnkube-controller) loops
   "Node connection status = connected" every 500ms and never writes
   the CNI config.
5. br-ex on both nodes: UNKNOWN state, 169.254.169.2/29 +
   10.44.0.0/32, fixed hwaddr 0a:59:00:00:00:01 - virtual by design,
   physical NIC never enslaved (differs from OpenShift configure-ovs).

## Ruled out (each was a real harness bug, all fixed, symptom persists)

- greenboot-healthcheck racing cleanup-data (fixed: stop first)
- firewalld blocking OVN DB/geneve ports between nodes (fixed: stop;
  distro TODO below)
- unresolvable peer hostnames (fixed: /etc/hosts)
- guest network colliding with 10.44.0.0/24 (fixed: moved to
  192.168.100.0/24; note 10.42/10.43/10.44 are all reserved)
- split networking, ssh via user-net + isolated cluster segment
  (fixed: single NAT bridge exactly like upstream docs)
- br-ex "rehoming" (red herring: microshift br-ex is virtual)

## Hypotheses, ranked

1. RULED OUT (run 30980996686, 2026-08-05): node2 runs a healthy
   control plane. `ss -ltn` shows *:6443 listening, `curl -ks
   https://10.44.0.0:6443/healthz` answers "ok" locally, microshift
   is active, and `journalctl -u microshift -p err` is empty on node2.
   The API plane is fine end to end.
2. OVN interconnect between the per-node zones is not established:
   northd's "No path" plus the connected-loop suggest the transit
   switch/chassis registration between zones never forms. Check
   ovn-sbctl on each node for remote chassis / transit switch ports,
   and whether microshift multinode expects ovn-ic daemons that are
   not shipped/enabled. THIS IS NOW THE PRIME SUSPECT.
3. The lease-holder design: if node2's CNI setup waits on a
   cluster-singleton master that only programs node1's databases,
   node2's zone is never programmed. Check which component writes the
   joined node's logical switch in multinode mode. (Closely related
   to 2; the fix likely answers both.)

## Distro-level fixes already identified (independent of the bug)

- postinstall.sh opens 6443/2379/2380 for multinode but not OVN:
  geneve 6081/udp and the OVN NB/SB ports. Upstream configure-node.sh
  just disables firewalld; the distro should open the right ports.
- The release images (release-x86_64.json refs) are not embedded, so
  first boot needs a registry (separate air-gap item, also affects
  multinode joins in the field).

## Reproducing

- CI: `gh workflow run replication-test --repo epheo/stornas`
  (~40 min to failure, full diagnostics dumped: pods, events,
  endpoints, per-node br-ex/routes/CNI dir, ovnkube logs, linstor
  state, consoles).
- Local (needs rootful podman + qemu + dnsmasq + sudo):
  `cd stornas && KEEP=1 make replication-test PODMAN='sudo podman'`
  KEEP=1 leaves both VMs and ssh keys in /tmp/stornas-repl.*
  (root@192.168.100.11 / .12) for interactive digging.
- Pure-distro repro without stornas is upstream's own flow:
  docs/contributor/multinode/setup.md with two VMs of this distro's
  image; the stornas layer plays no role in the failure (all stornas
  pods on node1 run fine; node2 failures are openshift-dns, multus,
  piraeus alike - anything needing CNI).

## Open questions for the next session on this repo

- Does `microshift run --multinode` change advertiseAddress handling,
  and does add-node bring up a full control plane on the secondary?
  (openshift/microshift: cmd/microshift, pkg/config, addnode.go -
  "initial cluster" log line comes from addnode.go:483.)
- Is the 4.22 multinode flow validated upstream against OKD SCOS
  payloads at all? The docs call multinode "not supported, test-only".
- Since both members run full control planes, is there supposed to be
  a per-zone ovnkube-master (no cluster-wide lease), and is the lease
  contention in evidence item 2 itself the bug?
