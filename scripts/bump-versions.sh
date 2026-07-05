#!/bin/bash
# Refresh versions.env with the newest available inputs WITHIN the currently
# pinned minor:
#   - openshift/microshift z-stream ART tag (e.g. 4.22.3-202606251354.p0)
#   - OKD stable payload tag              (e.g. 4.22.0-okd-scos.7)
#   - portail release                     (e.g. 0.1.17)
# Crossing to a new minor (or to the 5.0 renumbering) is a deliberate manual
# decision — this script never does it.
#
# Exits 0 whether or not anything changed; the workflow turns a dirty
# versions.env into a pull request.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source versions.env

MINOR="$(echo "${USHIFT_GITREF}" | cut -d. -f1,2)"

latest_ushift="$(git ls-remote --tags "${USHIFT_GIT_URL}" "refs/tags/${MINOR}.*" \
    | awk '{print $2}' | sed -e 's|refs/tags/||' -e 's|\^{}||' | sort -uV \
    | grep -vE -- '-(ec|rc)\.' | tail -1)"

latest_okd="$(skopeo list-tags "docker://${OKD_RELEASE_IMAGE}" \
    | jq -r '.Tags[]' | grep -E "^${MINOR//./\\.}\.[0-9]+-okd-scos\.[0-9]+$" \
    | sort -V | tail -1)"

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
