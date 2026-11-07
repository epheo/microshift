# Opinionated build of upstream MicroShift and OKD

From-source distribution of [MicroShift](https://github.com/openshift/microshift)
as a bootc OS image: CentOS Stream 10, native el10 RPMs.

Published at `ghcr.io/epheo/microshift`.

## The opinions

| Opinion | How |
|---|---|
| OVN-Kubernetes is the CNI | `microshift-networking` installed; no kindnet |
| OVN secondary networks work out of the box | `patches/0001` adds `enable-multi-network=true` to the ovnkube-config template at the source |
| Secondary networks take policies | `patches/0010` adds `enable-multi-networkpolicy=true` and the MultiNetworkPolicy CRD (taken at build time from the payload's cluster-network-operator) to MicroShift's own CRD list, applied before OVN starts: OVN-Kubernetes waits for it at start |
| Cluster-wide policies | `patches/0011` adds `enable-admin-network-policy=true`, the AdminNetworkPolicy and BaselineAdminNetworkPolicy CRDs (taken at build time from the payload's cluster-network-operator) to MicroShift's CRD list, and the OVN controller's rights to read them and write their status: a namespace's NetworkPolicy cannot override an admin Deny |
| Multus enabled | `microshift-multus` (config.d toggle + cri-o default-network drop-in) |
| r-drbd is the storage driver | [r-drbd](https://github.com/epheo/r-drbd) (DRBD 9 on thin LVM) with its DRBD module built for the image kernel; local volumes on one node, replicated ones on three. See [Storage](#storage) |
| Air-gapped by default | the full MicroShift payload is embedded as a shared-blob OCI layout and imported into cri-o at boot — first boot needs no registry |
| [portail](https://github.com/epheo/portail) is the edge | its image is embedded and imported the same way; the router is off and the Gateway API experimental CRDs (TCPRoute, UDPRoute) ship with the image, see [The edge](#the-edge) |
| Updates must be safe | greenboot MicroShift health gate stays enabled; bootc rollback does the rest; no node retries an image greenboot rolled back, and workers follow the image the controller booted green, see [Multinode](#multinode-experimental) |
| Logs are signal, not noise | `patches/0002` (etcd logs every request at warn — missing threshold default) and `patches/0003` (router status watcher hot-loops when `ingress.status: Removed`) |
| Terminated pod GC is tunable | `patches/0009` adds `kubeControllerManager.terminatedPodGCThreshold`, the pod garbage collector's threshold (default unchanged, 12500): set it lower where graceful node shutdown leaves many terminated pods |
| Every image can be controller or worker | `microshift-profile` selects the role; `patches/0006`-`0008` add a worker mode where nodes hold no signing keys and OVN runs one interconnect zone per node |
| The firewall is on and role-scoped | firewalld enabled with `microshift-controlplane`/`microshift-node` services; etcd is never exposed |
| Headless and quiet | `bluetooth.service` and `fwupd-refresh.timer` masked; Red Hat client stack (`rhc`, `insights-client`, `subscription-manager`) removed: no radio daemon, no daily LVFS fetch, no registration nag or phone-home |
| Native el10 | RPMs are built in a CentOS Stream 10 buildroot |

Everything site-specific (IPs, VLANs, NADs, hardware quirks, extra embedded
images) belongs in a derived image, not here. Site layers can drop additional
OCI archives + manifest lines under `/usr/lib/embedded-images/` and the boot
import service picks them up.

## Storage

[r-drbd](https://github.com/epheo/r-drbd) provides block storage: local
volumes (`r-drbd-local`, one replica) on any node, synchronously replicated
ones (`r-drbd-replicated`) on three nodes, snapshots, and expansion. Its
manifests (`src/r-drbd/base`) and the DRBD module are pinned in `versions.env`.

Storage works out of the box on the same shape TopoLVM used: create volume
group `myvg1` with a thin pool named `thin`, and on its next start the node
declares it as an r-drbd Pool and makes `r-drbd-local` the default
StorageClass. Any other layout is declared as a Pool by the site; see r-drbd's
[pools](https://github.com/epheo/r-drbd/blob/main/docs/pools.md). Workers'
Pools are always declared by the site.

```sh
vgcreate myvg1 /dev/sdb
lvcreate --type thin-pool -l 90%FREE -n thin myvg1
```

Upgrading a node that ran TopoLVM changes nothing on its own: without a thin
pool in `myvg1`, no Pool is declared, TopoLVM keeps running and serving its
volumes, and stays the default class. To move, back up the volumes, create the
thin pool, restore onto `r-drbd-local`, then remove TopoLVM
(`oc delete namespace topolvm-system`, its CSIDriver and StorageClass).

## The edge

portail replaces the OpenShift router.
`/etc/microshift/config.d/00-ingress-removed.yaml` turns the router off.
Upgrading an install that ran the router deletes it on the next start.
Drop-ins override `/etc/microshift/config.yaml`: to bring the router back, set `ingress.status: Managed` in a drop-in that sorts after `00-ingress-removed.yaml`.
The router image stays embedded, so that works air-gapped.

The Gateway API CRDs ship with the image, experimental channel, pinned in `versions.env`: TCPRoute and UDPRoute exist only there.
They apply from `/usr/lib/microshift/manifests.d/000-gateway-api`, before any site kustomization, so site Gateways and routes find them.
Site layers must not ship their own copy: MicroShift re-applies every kustomization at each start, and the last one wins.

## How it builds

Three container stages, driven by `make` and pinned by `versions.env`:

1. **`packaging/srpm.Containerfile`** — clone `openshift/microshift` at the
   pinned ART tag, apply `patches/*.patch`, swap the pinned OCP payload image
   digests for the public OKD SCOS payload (`quay.io/okd/scos-release`),
   drop the subpackages it cannot build, build the SRPM.
2. **`packaging/rpm.Containerfile`** — rebuild the SRPM into el10 RPMs in a
   CentOS Stream 10 buildroot (`microshift_variant community`).
3. **`packaging/bootc.Containerfile`** — build the DRBD module for the base
   kernel, install the RPM selection and r-drbd onto
   `centos-bootc:stream10`, embed the MicroShift payload and portail, enable
   the boot import service and greenboot.

Runtime dependencies (cri-o, openvswitch, openshift-clients, …) come from the
public `mirror.openshift.com` dependencies repo of the pinned minor (el9
builds). Payload images come from the OKD release: public, no pull secret.

```sh
make srpm rpm image        # build everything (rootless podman is fine)
sudo make smoke            # quick check: boot as a privileged container, assert opinions
sudo make vm-test          # acceptance: bootc-image-builder -> qcow2 -> QEMU boot,
                           # asserts opinions + real bootc deployment + greenboot GREEN
sudo make vm-test-upgrade  # the same assertions after a real update: boot the
                           # previously published image, bootc switch to the
                           # candidate, reboot
sudo make multinode-smoke  # worker join in two privileged containers: join
                           # mechanics, certs, cross-node pod/service traffic
sudo make multinode-test   # two-VM worker join: bootc deploy + firewalld +
                           # greenboot + the same cross-node dataplane asserts,
                           # then a controller update the worker follows
make version               # print the version string of the built RPMs
```

`vm-test` is the CI gate — it validates what the container smoke cannot:
bootloader, ostree deployment, boot ordering, greenboot actually gating
the boot, and the air-gapped contract (the fresh-install VM has zero
egress). Its opinion assertions are functional, not existence checks:
- the default r-drbd Pool comes up and a PVC with no class is provisioned and written;
- an OVN-K layer2 secondary network is attached through a
  NetworkAttachmentDefinition, a MultiNetworkPolicy cuts a pod off it, and
  removing the policy restores it;
- an AdminNetworkPolicy Deny does the same on the cluster network;
- the router is not deployed;
- the embedded portail image starts from cri-o's store with pull policy
  Never, and a re-pointed embedded tag is re-imported;
- the API accepts TCPRoute and UDPRoute objects;
- steady-state journal volume is capped (regression cover for the log-noise
  patches, which could silently go dead on a bump while still applying
  cleanly).

`vm-test-upgrade` runs the same suite on the update path every existing
install takes (boot the last published release, `bootc switch` to the
candidate, reboot), and also asserts that a file on `/var` and an etcd object
survived, that the data version moved to the candidate's, and that the
pre-upgrade data was backed up for a rollback. The upgrade itself is gated
before anything publishes. `smoke` remains the fast inner loop for local
iteration.

## Versioning

Image tags: `<microshift-version>_g<commit>_<okd-tag>_epheo.<rev>`, with
every dash turned into an underscore, e.g.
`4.22.20_202610260627.p0_g9879ed9a_4.22.0_okd_scos.10_epheo.20`, plus the
moving tags `<minor>` (e.g. `4.22`) and `latest`. `EPHEO_REV` in
`versions.env` tracks changes to the patch/opinion set itself.

A minor tag stops moving once main crosses to the next minor: it gets no more
z-streams and no more weekly rebuilds. Follow `latest`, or a minor tag only as
long as you accept that.

## Release cadence

The build workflow checks daily for new z-stream tags, OKD stable payload
tags, and portail releases. A bump is committed to the `auto/bump` branch,
never straight to main: the same run builds it, VM-tests it, upgrade-tests it
from the previous release and the previous minor, and only then fast-forwards
main to it and publishes. A weekly run rebuilds even with unchanged pins to
pick up package-level (CVE) fixes. Minor (and any future major) crossings are
automatic too, one minor per run, gated on one condition: a stable OKD payload
of the new minor must exist. There is no manual step in the release process:
the CI gate is the judge. A bump that breaks the build leaves main on the last
green pins, opens an "auto-bump-red" issue, and fails again daily, in seconds,
until an input or main moves (for example once `patches/` is rebased).

A node configured with custom feature gates (`featureSet: CustomNoUpgrade`)
refuses to start after any minor or major change, and greenboot rolls it
back: such a node must not follow `latest`.

## Multinode (experimental)

Upstream's community multinode joins every node as a full control plane
replica, CA private keys included — and its OVN manifests still describe
the central-mode architecture that ovn-kubernetes removed, so a second
node of any kind never gets networking. This distribution ships a worker
role instead (`patches/0006`, `0007`): `microshift run --worker` starts
only the node services, the kubelet bootstraps its client cert from the
bootstrap kubeconfig and obtains its serving cert through a CSR approved
by a small controller on the control plane, and `add-node --worker`
takes only the kubelet client CA bundle the control plane publishes, so a
worker never holds signing material.
`patches/0008` replaces the multinode OVN manifests with its own to match
the shipped binary: every node runs its own interconnect zone (local OVN
databases, northd, ovn-controller, zone controller), the control plane keeps only
the cluster manager, and ovnkube authenticates with a service account
instead of a mounted kubeadmin kubeconfig. Zone pods get OpenShift's
node-limited role, not the controller's: a worker can write pod and node
status, and ConfigMaps only in `openshift-ovn-kubernetes`. Workers boot from the same
embedded payload, so joins are air-gapped too. One image serves both
roles:

```sh
# on the controller (default profile): a join kubeconfig, valid 1h
# (--duration); --address is a name its apiserver certificate covers
microshift worker-join-kubeconfig --address <controller-addr> > join.kubeconfig

# on each worker
microshift-profile worker
microshift add-node --worker --kubeconfig /path/to/join.kubeconfig
```

The join kubeconfig holds a token for `kube-system/microshift-worker-join`:
it can request node client certificates and read the kubelet client CA
bundle, nothing else. Until it expires it can request a certificate for any
node name, so delete it after the join. `add-node` removes its own copy when
it exits, whether the join succeeded or not (a failed join is simply
re-run). After the join the kubelet holds only its own rotating cert, and
workers keep their kubelet client CA current
from the CA the control plane publishes, so control-plane CA rotation does not
require a re-join. The greenboot gate stays enabled on workers: `microshift
healthcheck` detects the role and gates on the node being Ready in the cluster.

Updates: the controller leads, workers follow.
- The controller updates on bootc's own timer, like a single node.
- Once a boot is green, it publishes the image it booted, by digest, in
  `kube-public/microshift-update`.
- Every 5 minutes a worker switches to that image when it runs another one
  (`microshift-update-follow.timer`); bootc's own timer stays idle on workers.
- So a worker updates minutes after the controller and never before it, as
  the Kubernetes version skew policy requires, and never to an image the
  controller rolled back.
- Workers pull from the controller's repository: an air-gapped site that
  mirrors it sets a `registries.conf` mirror.
- Until a worker has rebooted into the new image, its DaemonSet pods wait for
  images it does not hold yet, unless it can pull them.
- Any node records an image greenboot rolled back in
  `/var/lib/microshift-update/rolled-back`, and its updates skip that image
  until another one is published. A manual `bootc upgrade --apply` or
  `bootc switch` still applies it.
- A worker tracks a digest: after `microshift-profile controller`,
  `bootc switch` it to a tag to update on its own.
- One node at a time, the controller included: a node takes the Lease
  `kube-public/microshift-update` before it reboots into an update, and
  releases it once green again. A node that never comes back loses it after
  an hour.
- And only while no r-drbd Volume is Degraded or Provisioning: a second
  replica down could take a replicated volume below quorum. This is r-drbd's
  own rule for planned maintenance; a dead node therefore holds back every
  automatic update until its Volumes recover or are evicted.
- Backstop: a worker refuses to start a kubelet newer than the controller's
  apiserver, and greenboot rolls it back.

The firewall follows the profile (workers expose only kubelet and Geneve).
Note that upgrading a pre-existing install to this revision enables firewalld
if it was inactive: a site relying on previously open ports must add explicit
firewalld rules. Multinode remains upstream-unsupported and single-controller:
losing the controller means losing the cluster. Cluster-to-cluster (C2CC) routes reach pods
on the controller only: each worker is its own OVN zone, and the route manager
programs the controller's.

Two suites gate the topology: `multinode-smoke` (containers; join
mechanics, cert flow, cross-node pod-to-pod, pod-to-service and cluster
DNS) and `multinode-test` (two QEMU VMs; the same dataplane asserts on a
real bootc deployment with firewalld running and greenboot green on both
roles, then a controller update the worker follows by digest once the
update lock is free, and the update gate skipping a rolled-back image).

## Patch policy

`patches/` is a series applied on pristine upstream tags. Keep it short,
prefer asset/config patches over code patches, and upstream what can be
upstreamed. Every patch is rebase debt paid on each new pin.

Each patch is a `git format-patch` mail: its subject and body say why it
exists, what upstream does instead, and what test covers it. Work on the
series as commits, never by editing the files:

```sh
scripts/patches.sh tree /tmp/ushift     # upstream at the pin + one commit per patch
# edit in /tmp/ushift with plain git: commit --fixup + rebase -i --autosquash, reword...
scripts/patches.sh export /tmp/ushift   # write the commits back to patches/
scripts/patches.sh check                # apply on a pristine tag, as the SRPM stage does
```

After a bump to a new tag, `tree` stops at the first patch that no longer
applies (`git am --3way`, with the old base fetched for the 3-way merge):
resolve, `git am --continue`, then `export`. CI keeps applying with plain
`git apply`, so a patch that only applies by 3-way still fails the build.

`export` writes a file that is mostly an upstream file as a copy plus hunks
(`--find-copies-harder -C75%`): the zones DaemonSet in `patches/0008` is
upstream's single-node master DaemonSet with the zone changes on top, so
upstream fixes to that file reach it on the next pin, and only a change
under one of the hunks needs a hand rebase.

## Credits

The build approach and several scripts under `src/` are adapted from
[microshift-io/microshift](https://github.com/microshift-io/microshift)
(see `src/VENDORED.md`). MicroShift itself is Apache-2.0 by Red Hat.
