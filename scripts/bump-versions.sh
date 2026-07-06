#!/bin/bash
# Refresh versions.env with the newest available inputs:
#   - openshift/microshift GA z-stream ART tag (e.g. 4.22.3-202606251354.p0)
#   - OKD stable payload tag                   (e.g. 4.22.0-okd-scos.7)
#   - portail release                          (e.g. 0.1.17)
#
# Minor (and any future major) crossings are automatic, gated on one
# mechanical condition: a new upstream GA minor is adopted only once a stable
# OKD payload of the same minor exists — until then the script keeps shipping
# z-streams of the pinned minor. The CI gate (patch series applies, RPMs
# build, the VM boots green through greenboot on the recommended shape) is
# what actually guards a crossing; a crossing that breaks the patch series
# leaves main red until the series is rebased by hand. Never downgrades.
#
# Exits 0 whether or not anything changed; the workflow commits a dirty
# versions.env and the same run builds, VM-tests and publishes it.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source versions.env

# GA tags only (ec/rc excluded), version-sorted.
all_ushift="$(git ls-remote --tags "${USHIFT_GIT_URL}" 'refs/tags/*' \
    | awk '{print $2}' | sed -e 's|refs/tags/||' -e 's|\^{}||' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | grep -vE -- '-(ec|rc)\.' | sort -uV)"

all_okd="$(skopeo list-tags "docker://${OKD_RELEASE_IMAGE}" \
    | jq -r '.Tags[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-okd-scos\.[0-9]+$' \
    | sort -uV)"

# The newest minor released on BOTH sides, floored at the pinned minor.
cur_minor="$(echo "${USHIFT_GITREF}" | cut -d. -f1,2)"
common_minors="$(grep -Fxf <(echo "${all_ushift}" | cut -d. -f1,2 | sort -u) \
    <(echo "${all_okd}" | cut -d. -f1,2 | sort -u) || true)"
minor="$(printf '%s\n%s\n' "${cur_minor}" "${common_minors}" | sort -uV | tail -1)"
if [ "${minor}" != "${cur_minor}" ]; then
    echo "crossing: ${cur_minor} -> ${minor} (stable OKD payload available)"
fi

latest_ushift="$(echo "${all_ushift}" | grep -E "^${minor//./\\.}\." | tail -1)"
latest_okd="$(echo "${all_okd}" | grep -E "^${minor//./\\.}\." | tail -1)"

portail_repo="${PORTAIL_IMAGE%%:*}"
latest_portail="$(skopeo list-tags "docker://${portail_repo}" \
    | jq -r '.Tags[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

update() {
    local key=$1 cur=$2 new=$3
    if [ -n "${new}" ] && [ "${new}" != "${cur}" ]; then
        echo "bump: ${key} ${cur} -> ${new}"
        sed -i "s|^${key}=.*|${key}=${new}|" versions.env
    else
        echo "keep: ${key}=${cur}"
    fi
}

update USHIFT_GITREF   "${USHIFT_GITREF}"   "${latest_ushift}"
update OKD_VERSION_TAG "${OKD_VERSION_TAG}" "${latest_okd}"
update PORTAIL_IMAGE   "${PORTAIL_IMAGE}"   "${latest_portail:+${portail_repo}:${latest_portail}}"
