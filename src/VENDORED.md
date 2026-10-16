# Vendored files

The following files are copied from
[microshift-io/microshift](https://github.com/microshift-io/microshift)
(the MicroShift team's community/upstream project) and kept as close to
verbatim as possible so they can be diffed and re-synced against upstream:

| Path | Status |
|---|---|
| `src/image/prebuild.sh` | adapted (pins per-arch instance digests: the bootc stage embeds the payload byte-exact) |
| `src/image/build-rpms.sh` | verbatim, upstream c2e15e2 |
| `src/image/modify-spec.py` | verbatim, upstream f915e4c |
| `src/okd/get_version.sh` | verbatim, upstream 591f87e; not used by the build |
| `src/rpm/create_repos.sh` | verbatim, upstream 827a388 |
| `src/rpm/postinstall.sh` | adapted (kindnet handling removed: this distro is OVN-only) |
| `src/topolvm/**` | verbatim, upstream f13b69f, except: |
| `src/topolvm/topolvm.spec` | adapted (no disable-storage-csi dropin: patches/0004 makes driver-off the compiled default) |
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
