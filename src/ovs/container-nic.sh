#!/bin/bash
# In a container only (microshift-container-nic.service), before
# NetworkManager. The runtime sets up the NIC there: a veth, which OpenShift's
# NetworkManager config (sdn.conf) leaves unmanaged, so configure-ovs finds no
# profile to move into br-ex. Give it what a node's NIC has, a managed static
# profile with the address the runtime assigned: configure-ovs then builds the
# same br-ex as on a node.
set -euo pipefail

iface="$(ip -o -4 route show default | awk '{print $5; exit}')"
[ -n "${iface}" ] || { echo "no default route: no NIC to give a profile" >&2; exit 0; }
addr="$(ip -o -4 addr show dev "${iface}" scope global | awk '{print $4; exit}')"
gw="$(ip -o -4 route show default dev "${iface}" | awk '{print $3; exit}')"
[ -n "${addr}" ] || { echo "${iface} has no IPv4 address" >&2; exit 0; }

# A harness that seeded its own profile keeps it: two would race for the NIC.
if grep -lsx "interface-name=${iface}" /etc/NetworkManager/system-connections/* >/dev/null; then
    echo "${iface} already has a NetworkManager profile"
    exit 0
fi

# zz: after sdn.conf in the same directory, whose [device] section marks every
# veth unmanaged; the later file wins. dns=none: the runtime owns resolv.conf.
cat > /etc/NetworkManager/conf.d/zz-microshift-container.conf <<EOF
[main]
dns=none

[device-microshift-container]
match-device=interface-name:${iface}
managed=1
EOF

conn=/run/NetworkManager/system-connections/microshift-container.nmconnection
mkdir -p "$(dirname "${conn}")"
# NetworkManager skips a keyfile unless root owns it with mode 0600.
install -m 600 /dev/null "${conn}"
cat > "${conn}" <<EOF
[connection]
id=${iface}
type=ethernet
interface-name=${iface}

[ipv4]
method=manual
address1=${addr}${gw:+,${gw}}

[ipv6]
method=disabled
EOF
echo "gave ${iface} a static NetworkManager profile: ${addr} via ${gw:-no gateway}"
