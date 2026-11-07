#!/bin/bash
# Decides whether the upgrade lanes run vm-test.sh's rollback cycle, about
# 20 minutes each. It proves greenboot, grub and bootupd (from the base)
# and MicroShift's backup and restore (upstream), which our changes rarely
# touch. So it runs when one of those can have moved:
# - the weekly rebuild: the base drifts without a diff;
# - the upstream pin moves;
# - a change touches the rollback cycle in the test, a greenboot file,
#   src/update (it records rolled-back images), or a patch to upstream code
#   on the rollback path;
# - workflow_dispatch asks for it.
# Env: WEEKLY, ASKED (true or not), BASE (sha to compare HEAD with).
set -euo pipefail

decide() {
    echo "rollback cycle: $2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "enabled=$1" >> "${GITHUB_OUTPUT}"; fi
    exit 0
}

[ "${WEEKLY:-}" = true ] && decide 1 "on, weekly rebuild"
[ "${ASKED:-}" = true ] && decide 1 "on, asked"
[ -n "${BASE:-}" ] || decide "" "off, nothing to compare with"
[ "${BASE}" != "$(git rev-parse HEAD)" ] || decide "" "off, no change"

# Unknown is not safe: test rather than skip.
git cat-file -e "${BASE}^{commit}" 2>/dev/null \
    || git fetch -q --depth=1 origin "${BASE}" \
    || decide 1 "on, base ${BASE} not fetchable"

# red.d's restore marker and the restore itself. Not cleanup-data: red.d
# runs it after the marker, so it cannot stop a rollback.
upstream_path='^diff --git a/(pkg/admin/|packaging/greenboot/)'

while IFS=$'\t' read -r status path; do
    case "${path}" in
        scripts/ci-rollback-needed.sh|*greenboot*|src/update/*)
            decide 1 "on, ${path} changed" ;;
        scripts/vm-test.sh)
            # Most edits add asserts elsewhere; the weekly run covers drift.
            if git diff "${BASE}" HEAD -- "${path}" \
                    | grep -iE '^[-+].*(rollback|force_red|upgrade_to_candidate|booted_image|greenboot)' >/dev/null; then
                decide 1 "on, the rollback cycle in ${path} changed"
            fi ;;
        patches/*.patch)
            # A removed patch counts by what it used to change.
            rev=HEAD
            [ "${status}" = D ] && rev="${BASE}"
            # Not grep -q: an early exit would fail the pipe (pipefail).
            if git show "${rev}:${path}" | grep -E "${upstream_path}" >/dev/null; then
                decide 1 "on, ${path} patches the rollback path"
            fi ;;
    esac
done < <(git diff --name-status --no-renames "${BASE}" HEAD)

if git diff "${BASE}" HEAD -- versions.env | grep -E '^[-+]USHIFT_GITREF=' >/dev/null; then
    decide 1 "on, upstream pin moved"
fi

decide "" "off, nothing on the rollback path changed"
