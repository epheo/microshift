# shellcheck shell=bash
# Sourced by the container smoke tests. A container's eth0 is a veth that
# podman configures, and NetworkManager ignores veths (sdn.conf), so
# configure-ovs finds no connection to move into br-ex. Give eth0 what a host
# NIC has: a static NetworkManager profile, managed. Then configure-ovs moves
# it into br-ex as on any node.

# nic_network NAME PREFIX: a podman network PREFIX.0/24, gateway PREFIX.1.
# Keep PREFIX out of 10.42-10.43 (pods, services).
nic_network() {
    sudo podman network create --subnet "$2.0/24" --gateway "$2.1" "$1" >/dev/null
}

# nic_install CONTAINER IP GATEWAY: on a created, not yet started container.
nic_install() {
    local d
    d="$(mktemp -d)"
    cat > "${d}/eth0.nmconnection" <<EOF
[connection]
id=eth0
type=ethernet
interface-name=eth0

[ipv4]
method=manual
address1=$2/24,$3

[ipv6]
method=disabled
EOF
    # zz: after sdn.conf, whose [device] marks every veth unmanaged; a later
    # file wins. dns=none leaves podman's resolv.conf, its DNS names the nodes.
    cat > "${d}/zz-container-eth0.conf" <<'EOF'
[main]
dns=none

[device-container-eth0]
match-device=interface-name:eth0
managed=1
EOF
    # NetworkManager skips a keyfile not owned by root with mode 0600.
    sudo chown root:root "${d}"/*
    sudo chmod 600 "${d}/eth0.nmconnection"
    sudo podman cp "${d}/eth0.nmconnection" "$1:/etc/NetworkManager/system-connections/eth0.nmconnection"
    sudo podman cp "${d}/zz-container-eth0.conf" "$1:/etc/NetworkManager/conf.d/zz-container-eth0.conf"
    sudo rm -rf "${d}"
}
