# Vendored files

The following files are copied from
[microshift-io/microshift](https://github.com/microshift-io/microshift)
(the MicroShift team's community/upstream project) and kept as close to
verbatim as possible so they can be diffed and re-synced against upstream:

| Path | Status |
|---|---|
| `src/image/prebuild.sh` | verbatim |
| `src/image/build-rpms.sh` | verbatim |
| `src/image/modify-spec.py` | verbatim |
| `src/okd/get_version.sh` | verbatim |
| `src/rpm/create_repos.sh` | verbatim |
| `src/rpm/postinstall.sh` | adapted (kindnet handling removed — this distro is OVN-only) |
| `src/topolvm/**` | verbatim |
| `packaging/*.Containerfile` | rewritten, derived from their equivalents |

Note: microshift-io/microshift currently ships no LICENSE file (tracked
upstream; the underlying MicroShift sources are Apache-2.0). These files are
vendored with attribution; if upstream adds a license, it applies to them.

`src/embedded-images/` is NOT vendored — it is this distribution's own
boot-time image import mechanism (originally developed in the konstruct lab
repo).
