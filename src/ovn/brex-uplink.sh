#!/bin/sh
# OKD's ovn-kubernetes (since 4.22.0-okd-scos.8) resolves the gateway
# bridge uplink as: external-ids:bridge-uplink, else the single
# system-type port, else the bridge name minus its "br" prefix.
# MicroShift's configure-ovs never enslaves a NIC, so br-ex has no
# uplink and the fallback yields the nonexistent interface "-ex";
# ovnkube-controller dies fetching its ofport and the node never goes
# Ready. Give the lookup a real answer: a dead internal port. Egress
# flows sent to it are dropped, which is what no uplink already meant.
set -eux

ovs-vsctl --timeout=15 --may-exist add-port br-ex brex-uplink \
    -- set interface brex-uplink type=internal
ovs-vsctl --timeout=15 br-set-external-id br-ex bridge-uplink brex-uplink
# The internal port surfaces as a kernel netdev; keep NetworkManager
# from running DHCP on it. Best effort: the netdev may not exist yet.
nmcli device set brex-uplink managed no || true
