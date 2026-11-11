#!/bin/bash
# Print the key CI caches the srpm and rpm stages' output under. It changes
# with anything those stages read:
# - their make recipes, the pins they pass, and the paths the cache keeps;
# - every file their Containerfiles COPY, read from the Containerfiles, so a
#   new COPY is keyed without editing this script;
# - the buildroot image as pulled, since its tag moves;
# - the ISO week: the rpm stage installs golang from the live mirror, and the
#   weekly rebuild must pick up toolchain fixes.
# Not keyed: the srpm stage's Fedora image, which only runs git, curl and
# rpmbuild -bs.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck source=versions.env
. ./versions.env
set +a
PODMAN="${PODMAN:-sudo podman}"

inputs() {
    for f in packaging/srpm.Containerfile packaging/rpm.Containerfile; do
        echo "${f}"
        awk '/^COPY/ && !/--from/ { for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i }' "${f}"
    done | sed 's#^\./##' | sort -u | xargs -I{} find {} -type f | sort
}

# Gathered before hashing: a failure inside the hashed pipeline would still
# print a key, of partial input.
buildroot="$(${PODMAN} image inspect --format '{{.Digest}}' "${BUILDROOT_IMAGE}")"
files="$(inputs)"
[ -n "${buildroot}" ] && [ -n "${files}" ]
# shellcheck disable=SC2086
sums="$(sha256sum ${files})"

{
    # What the cache keeps is part of the key: a path added later must not
    # restore an entry saved without it.
    sed -n '/^srpm:/,/^$/p; /^rpm:/,/^$/p; /^RPM_CACHE_PATHS/,/[^\\]$/p' Makefile
    for v in USHIFT_GIT_URL USHIFT_GITREF OKD_VERSION_TAG OKD_RELEASE_IMAGE BUILDROOT_IMAGE; do
        echo "${v}=${!v}"
    done
    echo "${buildroot}"
    date -u +%G-W%V
    echo "${sums}"
} | sha256sum | cut -c1-16
