# shellcheck shell=bash
# Sourced by vm-test.sh and multinode-test.sh. QEMU and dnsmasq run from the
# host, or with QEMU_IMAGE set (CI) from that image: the runner then needs no
# host packages. GitHub's runners only come as Ubuntu, and its package
# mirrors were what hung every VM lane on 2026-11-11.

# --pid host: pidfiles hold host PIDs, which the cleanups kill.
_ci_tool() { # _ci_tool CMD ARGS...: CMD from QEMU_IMAGE, in the background
    sudo podman run -d --rm --privileged --network host --pid host \
        -v /dev:/dev -v /tmp:/tmp "${QEMU_IMAGE}" "$@" >/dev/null
}

_wait_pidfile() {
    local _
    for _ in $(seq 60); do
        sudo test -s "$1" && return 0
        sleep 1
    done
    echo "ERROR: no $1 after 60s" >&2
    return 1
}

# qemu_start PIDFILE ARGS...: a VM in the background, its PID in PIDFILE.
qemu_start() {
    local pidfile=$1
    shift
    if [ -z "${QEMU_IMAGE:-}" ]; then
        sudo qemu-system-x86_64 "$@" -daemonize -pidfile "${pidfile}"
        return
    fi
    sudo rm -f "${pidfile}"
    _ci_tool qemu-system-x86_64 "$@" -pidfile "${pidfile}"
    _wait_pidfile "${pidfile}"
}

# dnsmasq_start PIDFILE ARGS...: dnsmasq in the background, its PID in PIDFILE.
dnsmasq_start() {
    local pidfile=$1
    shift
    if [ -z "${QEMU_IMAGE:-}" ]; then
        sudo dnsmasq "$@" --pid-file="${pidfile}"
        return
    fi
    sudo rm -f "${pidfile}"
    _ci_tool dnsmasq --keep-in-foreground "$@" --pid-file="${pidfile}"
    _wait_pidfile "${pidfile}"
}
