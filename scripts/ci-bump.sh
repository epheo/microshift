#!/bin/bash
# The daily bump, for CI: recompute the pins on top of main and stage the
# result on the bump branch. main itself only moves once that commit is
# green: the build job fast-forwards it. Writes to GITHUB_OUTPUT (stdout
# outside Actions):
#   changed  true when the pins moved
#   sha      the commit to build (empty when nothing moved)
#   stale    true when the bump branch already holds this exact bump on this
#            exact main: the last attempt failed and nothing new can change
#            that, so the run reports instead of rebuilding
# Expects a checkout with history and push rights on origin.
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH="${BUMP_BRANCH:-auto/bump}"
out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

git fetch -q origin main
if git fetch -q origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" 2>/dev/null; then
    staged=true
else
    staged=false
fi
git checkout -q -B bump origin/main

./scripts/bump-versions.sh
if git diff --quiet versions.env; then
    out changed false
    out stale false
    out sha ""
    exit 0
fi

if ${staged} &&
    [ "$(git rev-parse "origin/${BRANCH}~1")" = "$(git rev-parse origin/main)" ] &&
    git diff --quiet "origin/${BRANCH}" -- versions.env; then
    git checkout -q -- versions.env
    out changed true
    out stale true
    out sha "$(git rev-parse "origin/${BRANCH}")"
    exit 0
fi

git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "chore: bump pinned versions" \
    -m "$(git diff versions.env | grep '^[+-][A-Z]' || true)" -- versions.env src/rbac src/ovs
# The branch only ever holds the latest attempt.
git push -q --force origin "HEAD:refs/heads/${BRANCH}"
out changed true
out stale false
out sha "$(git rev-parse HEAD)"
