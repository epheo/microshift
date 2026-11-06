#!/bin/bash
# Work on the patch series as git commits instead of diff files.
#
#   scripts/patches.sh tree DIR    clone openshift/microshift at USHIFT_GITREF
#                                  into DIR and apply the series there, one
#                                  commit per patch. After a bump to a new tag,
#                                  git am stops at the first patch that needs
#                                  a hand rebase: fix it, `git am --continue`.
#   scripts/patches.sh export DIR  write DIR's commits since USHIFT_GITREF back
#                                  to patches/, replacing the series. Edit the
#                                  series with plain git in DIR first (commit
#                                  --fixup + rebase --autosquash, reword, ...).
#   scripts/patches.sh check       apply the series to a pristine USHIFT_GITREF
#                                  exactly as packaging/srpm.Containerfile does.
#
# Each patch is a format-patch mail: the subject and body say why it exists,
# what upstream does, and what covers it. Full index lines and the recorded
# base commit give git am a 3-way fallback when the series meets a new tag.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO}/versions.env"
PATCHES="${REPO}/patches"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# git am and rebase need an identity even where the user has none set.
git_id() {
    git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo patches)}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo patches@localhost)}" "$@"
}

clone_at() {
    local dir=$1
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${USHIFT_GITREF}" "${USHIFT_GIT_URL}" "${dir}"
}

cmd_tree() {
    local dir=${1:?usage: patches.sh tree DIR}
    [ -e "${dir}" ] && { echo "ERROR: ${dir} exists" >&2; exit 1; }
    clone_at "${dir}"
    # The commit the series was exported against: fetched so git am -3 has
    # the preimage blobs when the series meets a newer tag.
    local base
    base="$(sed -n 's/^base-commit: //p' "${PATCHES}"/0001-*.patch | head -1)"
    if [ -n "${base}" ] && ! git -C "${dir}" cat-file -e "${base}^{commit}" 2>/dev/null; then
        git -C "${dir}" fetch -q --depth 1 origin "${base}" || \
            echo "WARNING: could not fetch base ${base}; git am has no 3-way fallback" >&2
    fi
    git_id -C "${dir}" am -q --3way "${PATCHES}"/*.patch
    git -C "${dir}" log --oneline "${USHIFT_GITREF}..HEAD"
}

cmd_export() {
    local dir=${1:?usage: patches.sh export DIR}
    local base
    base="$(git -C "${dir}" rev-parse "${USHIFT_GITREF}^{commit}")"
    rm -f "${PATCHES}"/*.patch
    # Copies: zones/node/daemonset.yaml is upstream's single-node master
    # DaemonSet plus hunks, so upstream fixes to it reach the zones at apply
    # time and only edits under a hunk conflict. 75% keeps the narrow zone
    # RBAC from becoming a copy of the controller role, whose upstream
    # additions would then widen it silently.
    git -C "${dir}" format-patch -q --full-index --zero-commit --no-signature \
        --find-copies-harder -C75% \
        --base="${base}" -o "${PATCHES}" "${base}"
    ls "${PATCHES}"
}

cmd_check() {
    local dir
    dir="$(mktemp -d)"
    # Expanded now: the trap runs after this function's locals are gone.
    # shellcheck disable=SC2064
    trap "rm -rf '${dir}'" EXIT
    clone_at "${dir}/src"
    for p in "${PATCHES}"/*.patch; do
        echo "Applying $(basename "${p}")"
        git -C "${dir}/src" apply "${p}"
    done
    echo "series applies on ${USHIFT_GITREF}"
}

case "${1:-}" in
tree) cmd_tree "${2:-}" ;;
export) cmd_export "${2:-}" ;;
check) cmd_check ;;
*) usage ;;
esac
