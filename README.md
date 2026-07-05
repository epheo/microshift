# epheo's build of MicroShift

An opinionated, from-source distribution of [MicroShift](https://github.com/openshift/microshift)
as a bootc OS image — CentOS Stream 10, native el10 RPMs, fully public build
inputs (no Red Hat subscription or pull secret required).

Published at `ghcr.io/epheo/microshift`.

## Why this exists

The [microshift-io](https://github.com/microshift-io/microshift) community
project (run by the MicroShift team) proves that MicroShift builds cleanly
against the public OKD payload, but its bootc image releases are manual and
infrequent, ship kindnet as the CNI, and mix el9 RPMs onto el10 hosts. This
repo owns the release button: pinned, reproducible inputs; a CI build for
every z-stream; and a small set of opinions applied at the *source* level
instead of as runtime hacks.

## The opinions

| Opinion | How |
|---|---|
| OVN-Kubernetes is the CNI | `microshift-networking` installed; no kindnet |
| OVN secondary networks work out of the box | `patches/0001` adds `enable-multi-network=true` to the ovnkube-config template at the source |
| Multus enabled | `microshift-multus` (config.d toggle + cri-o default-network drop-in) |
| TopoLVM is the storage driver | community subpackage merged into the spec (LVMS is not in the OKD payload) |
| [portail](https://github.com/epheo/portail) is the edge | its image is embedded as an OCI archive and imported into cri-o at boot — cold boot needs no registry |
| Updates must be safe | greenboot MicroShift health gate stays enabled; bootc rollback does the rest |
| Native el10 | RPMs are built in a CentOS Stream 10 buildroot |

Everything site-specific (IPs, VLANs, NADs, hardware quirks, extra embedded
images) belongs in a derived image, not here. Site layers can drop additional
OCI archives + manifest lines under `/usr/lib/embedded-images/` and the boot
import service picks them up.

## How it builds

Three container stages, driven by `make` and pinned by `versions.env`:

1. **`packaging/srpm.Containerfile`** — clone `openshift/microshift` at the
   pinned ART tag, apply `patches/*.patch`, swap the pinned OCP payload image
   digests for the public OKD SCOS payload (`quay.io/okd/scos-release`),
   merge the TopoLVM subpackage, build the SRPM.
2. **`packaging/rpm.Containerfile`** — rebuild the SRPM into el10 RPMs in a
   CentOS Stream 10 buildroot (`microshift_variant community`).
3. **`packaging/bootc.Containerfile`** — install the RPM selection onto
   `centos-bootc:stream10`, embed portail, enable the boot import service and
   greenboot.

Runtime dependencies (cri-o, openvswitch, openshift-clients, …) come from the
public `mirror.openshift.com` dependencies repo. Payload images come from the
OKD release — public, no pull secret.

```sh
make srpm rpm image   # build everything (rootless podman is fine)
sudo make smoke       # quick check: boot as a privileged container, assert opinions
sudo make vm-test     # acceptance: bootc-image-builder -> qcow2 -> QEMU boot,
                      # asserts opinions + real bootc deployment + greenboot GREEN
make version          # print the version string of the built RPMs
```

`vm-test` is the CI gate — it validates what the container smoke cannot:
bootloader, ostree deployment, boot ordering, and greenboot actually gating
the boot. `smoke` remains the fast inner loop for local iteration.

## Versioning

Image tags: `<microshift-version>_g<commit>_<okd-tag>_epheo.<rev>` plus the
moving tags `<minor>` (e.g. `4.22`) and `latest`. `EPHEO_REV` in
`versions.env` tracks changes to the patch/opinion set itself.

## Release cadence

`.github/workflows/bump.yaml` checks weekly for new z-stream tags, OKD stable
payload tags, and portail releases within the pinned minor, and opens a PR.
Merging it builds, smoke-tests, and publishes. Crossing minors (including the
4.x → 5.0 renumbering) is a deliberate manual edit of `versions.env`.

## Patch policy

`patches/` is a series applied on pristine upstream tags. Keep it short,
prefer asset/config patches over code patches, and upstream what can be
upstreamed. Every patch is rebase debt paid on each new pin.

## Credits

The build approach and several scripts under `src/` are adapted from
[microshift-io/microshift](https://github.com/microshift-io/microshift)
(see `src/VENDORED.md`). MicroShift itself is Apache-2.0 by Red Hat.
