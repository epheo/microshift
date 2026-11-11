#!/bin/bash
# snapshot: record the base image's package versions, before any dnf.
# check:    fail if a dnf transaction since then downgraded one of them.
#
# The base is built from a CentOS Stream compose the mirror may not carry
# yet. A dnf install then downgrades base packages to the mirror's older
# builds while their libraries stay at the base's, and rpm's dependencies do
# not catch it: 2026-11-11, nftables 1.1.7 -> 1.1.5 on libnftnl 1.3.2 left
# firewalld unable to start, on an image that passed every other check.
set -euo pipefail

SNAPSHOT=/tmp/base-rpms

# One line per name.arch installed exactly once; gpg-pubkey and kernels can
# hold several versions side by side.
list() {
    rpm -qa --qf '%{NAME}.%{ARCH} %{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' |
        sort | awk '{n[$1]++; v[$1] = $2} END {for (k in n) if (n[k] == 1) print k, v[k]}' | sort
}

case "${1:-}" in
snapshot)
    list > "${SNAPSHOT}"
    ;;
check)
    down=0
    while read -r name was now; do
        [ "${was}" = "${now}" ] && continue
        if [ "$(rpm --eval "%{lua: print(rpm.ver('${now}') < rpm.ver('${was}'))}")" = true ]; then
            echo "ERROR: dnf downgraded ${name} ${was} -> ${now}" >&2
            down=1
        fi
    done < <(join "${SNAPSHOT}" <(list))
    if [ "${down}" = 1 ]; then
        echo "The mirror lags the compose the base was built from (its redhat.compose-id label)." >&2
        echo "Rebuild once the mirror has caught up." >&2
        exit 1
    fi
    rm -f "${SNAPSHOT}"
    ;;
*)
    echo "Usage: $0 snapshot|check" >&2
    exit 1
    ;;
esac
