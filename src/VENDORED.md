# Vendored files

The following files are copied from
[microshift-io/microshift](https://github.com/microshift-io/microshift)
(the MicroShift team's community/upstream project) and kept as close to
verbatim as possible so they can be diffed and re-synced against upstream:

| Path | Status |
|---|---|
| `src/image/prebuild.sh` | adapted (pins per-arch instance digests: the bootc stage embeds the payload byte-exact) |
| `src/image/build-rpms.sh` | verbatim, upstream c2e15e2 |
| `src/image/modify-spec.py` | verbatim, upstream 5587591 |
| `src/rpm/create_repos.sh` | verbatim, upstream 5587591 |
| `src/rpm/postinstall.sh` | adapted (kindnet handling removed: this distro is OVN-only) |
| `src/topolvm/**` | adapted from upstream f13b69f: chart 17.3.1 instead of 15.5.2 (Kubernetes 1.36 support), no webhook cert patches, `assets/delete/` removes the 15.x webhook on upgrade; also: |
| `src/topolvm/topolvm.spec` | adapted (no disable-storage-csi dropin: community builds never deploy LVMS, and patches/0004 keeps the healthcheck from expecting it) |
| `src/topolvm/greenboot/microshift-topolvm-check.sh` | adapted (skips on multinode workers) |
| `packaging/*.Containerfile` | rewritten, derived from their equivalents |

Upstream refs are microshift-io/microshift commits whose copy matches ours.
Before re-syncing an adapted file, carry its local change over; a verbatim
copy would silently drop it.

Note: microshift-io/microshift currently ships no LICENSE file (tracked
upstream; the underlying MicroShift sources are Apache-2.0). These files are
vendored with attribution; if upstream adds a license, it applies to them.

`src/embedded-images/` is NOT vendored — it is this distribution's own
boot-time image import mechanism (originally developed in the konstruct lab
repo).
