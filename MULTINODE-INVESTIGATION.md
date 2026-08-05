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
2. CONFIRMED, sharpened into the root cause below (2026-08-05,
   static source analysis at tag 4.22.4-202607070723.p0).
3. CONFIRMED as part of the same mechanism.

## Root cause (confirmed statically, 2026-08-05)

There is no OVN interconnect in microshift multinode at this tag.
There are no zones, no transit switches, no ovn-ic daemons.
The multi-node assets assume exactly one master-labeled node.
Plain add-node creates a second one, and the topology collapses:

- add-node joins etcd and brings up a full control plane on node2,
  which self-labels master like any microshift node
  (pkg/cmd/addnode.go; "What works" above shows both nodes with
  the master role).
- The multi-node ovnkube-master daemonset selects
  node-role.kubernetes.io/master, so it lands on both nodes
  (assets/components/ovn/multi-node/master/daemonset.yaml:471).
- Each master pod bootstraps NB/SB with ovn-ctl run_nb_ovsdb using
  only --db-nb-cluster-local-* flags; no --db-*-cluster-remote-addr
  exists anywhere in the asset. Each node therefore runs its own
  single-member raft: two disjoint OVN database pairs, never joined.
- ovnkube-node and ovnkube-master pass no NB/SB address flags and
  the ovnkube-config configmap has no [ovnnorth]/[ovnsouth]
  sections, so every consumer defaults to the LOCAL unix sockets in
  /run/ovn (hostPath). ovn-controller reads ovn-remote from local
  OVS external_ids, which ovnkube-node sets from the same default.
  Every node talks only to its own database.
- ovnkube-master is a cluster-singleton lease ([masterha] in the
  configmap). Node1 wins; node2's master loops forever (evidence
  item: two masters, node2 stuck on the lease). The leader writes
  node2's subnet and routes into NODE1's NB only.
- Node2's chassis never registers in node1's SB (its ovn-controller
  only knows its own empty SB), so node1's northd logs "No path for
  static route 10.42.1.0/24". Node2's ovnkube-node waits on OVN
  state that never arrives and never writes
  /etc/cni/net.d/10-ovn-kubernetes.conf (the readinessProbe is
  literally test -f on that file).
- Bonus fight: both control planes run the components controller
  and both render the cluster-scoped daemonsets with
  OVN_NB/SB_DB_LIST = tcp:<own NodeIP>:664x, because
  ConfigMultiNode hardcodes Controlplane = local NodeIP
  (pkg/config/multinode.go:16) and add-node never records the real
  controlplane IP. Last renderer wins; the endpoints flap.

So the dual-control-plane join cannot work at this tag by
construction. No firewall, DNS, or topology fix on our side changes
that. pkg/config/multinode.go says it outright: "only one
controlplane node is supported". Upstream's own
scripts/multinode/configure-node.sh drives exactly the failing flow
(plain add-node, full second control plane, no OVN wiring), so the
upstream dev-preview flow is broken the same way; consistent with
upstream's move toward an explicit worker role.

Implication for the fix: the worker-role branch (patches 0006/0007)
is not just hardening, it is the only topology these assets can
support. One master-labeled node, workers without the master label,
single OVN database pair on the controlplane.

Deeper layer, found while fixing the worker (2026-08-05, CI runs
30994415951..31002487265): pointing a worker at remote databases is
not even possible. ovn-kubernetes removed central mode in this
release; OVN DB connections are unix-socket only (the OvnAuthConfig
comment says so outright) and there is no [ovnnorth]/[ovnsouth]
address to configure. The single-node assets were already ported to
the modern layout (--init-cluster-manager plus a combined
--init-ovnkube-controller/--init-node container); the multi-node
assets never were. patches/0008 rewrites them: every node runs its
own interconnect zone (local nbdb/sbdb/northd/ovn-controller plus
the combined zone controller with --zone), the master daemonset
keeps only the cluster manager, and ovnkube authenticates with the
pod service account against https://<controlplane>:6443 because
CA-less workers have no kubeadmin kubeconfig to mount. Three
follow-on fixes that surfaced one per CI run, each fatal only
because SA auth made RBAC and startup checks real for the first
time: the k8s.cni.cncf.io informer RBAC (enable-multi-network),
the auth-priority rule that clears Token when the config file sets
tokenFile (set only apiserver= and let SA autodetection fill the
rest), and naming each node's NBDB zone in nbdb post-start
(nb_global name/options:name, as CNO's script-lib does).

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

## Open questions, answered 2026-08-05

- Does add-node bring up a full control plane on the secondary?
  Yes: etcd member join plus the whole stack; node2 self-labels
  master. That label is what doubles ovnkube-master.
- Is there supposed to be a per-zone ovnkube-master? No. No zones,
  no interconnect, singleton lease by design. The lease contention
  is a symptom of the unsupported second master, not the bug itself.
- Upstream validation: their own configure-node.sh flow hits the
  same wall; multinode at this tag only makes sense with a single
  master-labeled node.

## Resolution (2026-08-05, run 31010457141)

MULTINODE SMOKE TEST PASSED end to end on the worker topology:
worker Ready with worker-only labels, no signing material, CSR
bootstrap + serving cert flow, apiserver to kubelet TLS, OVN and
DNS pods Running and Ready on the worker (the CNI config that this
whole investigation was about gets written), healthcheck gating.
Two last worker-side fixes after the zone rewrite: br-ex carries
the node IP as a /32 alias (gateway init refuses an IP-less
interface), and the virtual advertise address is routed via the
control plane IP that add-node --worker records in the worker
marker, so pod traffic to the apiserver endpoint leaves the node.
That route is the direct fix for the very first piece of evidence
collected here (the endpoint dead-ending on the joined node).

## Remaining, beyond the smoke

- Two-VM vm-test join scenario (bootc deploy + greenboot gating).
- Cross-node pod-to-pod and pod-to-service traffic depth beyond
  the readiness probes the smoke asserts.
- The dual-control-plane path stays a bug repro only; upstream
  proposal material: worker role series (patches/0006-0008).
