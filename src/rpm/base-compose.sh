#!/bin/bash
# add:    point dnf at the CentOS Stream compose this base image was built
#         from, next to the mirror.
# remove: drop it again; the shipped image keeps the base's repos only.
#
# A fresh base carries builds the mirror trails by days. dnf then resolves to
# the mirror's older builds: kernel-devel for the base kernel is missing, and
# installs downgrade base packages out of step with their libraries
# (src/rpm/base-rpms.sh). The compose's packages carry the same CentOS key.
set -euo pipefail

REPO=/etc/yum.repos.d/base-compose.repo

case "${1:-}" in
add)
    compose="$(sed -n 's/.*"redhat.compose-id": "\([^"]*\)".*/\1/p' /usr/share/buildinfo/labels.json)"
    [ -n "${compose}" ] || {
        echo "ERROR: no redhat.compose-id in /usr/share/buildinfo/labels.json" >&2
        exit 1
    }
    # CentOS-Stream-10-20261110.0 lives under stream-10/.
    major="$(echo "${compose}" | sed -n 's/^CentOS-Stream-\([0-9]*\)-.*/\1/p')"
    url="https://composes.stream.centos.org/stream-${major}/production/${compose}/compose"
    for r in BaseOS AppStream; do
        # Composes are kept about a month; by then the mirror has caught up.
        printf '%s\n' "[base-compose-${r,,}]" \
            "name=${r} of ${compose}, the compose this base was built from" \
            "baseurl=${url}/${r}/\$basearch/os/" \
            'gpgcheck=1' \
            'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial-SHA256' \
            'skip_if_unavailable=1' ''
    done > "${REPO}"
    ;;
remove)
    rm -f "${REPO}"
    ;;
*)
    echo "Usage: $0 add|remove" >&2
    exit 1
    ;;
esac
