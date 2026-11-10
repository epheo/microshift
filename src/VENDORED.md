# Vendored files

The following files are copied from
[microshift-io/microshift](https://github.com/microshift-io/microshift)
(the MicroShift team's community/upstream project) and kept as close to
verbatim as possible so they can be diffed and re-synced against upstream:

| Path | Status |
|---|---|
| `src/image/prebuild.sh` | adapted (pins per-arch instance digests: the bootc stage embeds the payload byte-exact) |
| `src/image/build-rpms.sh` | verbatim, upstream c2e15e2 |
| `src/image/modify-spec.py` | adapted from upstream 5587591: runs with no spec to merge (TopoLVM's was the only one) |
| `src/rpm/create_repos.sh` | verbatim, upstream 5587591 |
| `src/rpm/postinstall.sh` | adapted (kindnet handling removed: this distro is OVN-only) |
| `packaging/*.Containerfile` | rewritten, derived from their equivalents |

Upstream refs are microshift-io/microshift commits whose copy matches ours.
Before re-syncing an adapted file, carry its local change over; a verbatim
copy would silently drop it.

Note: microshift-io/microshift currently ships no LICENSE file (tracked
upstream; the underlying MicroShift sources are Apache-2.0). These files are
vendored with attribution; if upstream adds a license, it applies to them.

`src/r-drbd/base/` is epheo/r-drbd's deploy/base at `R_DRBD_COMMIT`, verbatim
(`src/r-drbd/vendor.sh`); the rest of `src/r-drbd/` is this distribution's.

`src/ovs/` holds OpenShift's br-ex setup from openshift/machine-config-operator
at the commit the pinned OKD payload names, verbatim (`src/ovs/vendor.sh`):
`configure-ovs.sh`, `nm-ignore-sdn.conf` and the two OVS restart drop-ins.
`microshift-ovs-init.conf`, `nodeip-hint.sh` and `vendor.sh` are this distribution's.

`src/cni/plugins-image` pins the pinned OKD payload's container-networking-plugins
image (`src/cni/vendor.sh`); the build copies host-device from it.

`src/embedded-images/` is NOT vendored — it is this distribution's own
boot-time image import mechanism (originally developed in the konstruct lab
repo).
