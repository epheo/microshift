#!/bin/bash
# Post-install configuration for the bootc image.
# Adapted from microshift-io/microshift src/rpm/postinstall.sh — the kindnet
# handling is dropped: this distribution always ships OVN-Kubernetes, so
# openvswitch stays enabled and no external CNI plugins are needed.
set -euo pipefail
set -x

# Check if the script is running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Configure network and add some useful utilities
dnf install -y firewalld jq bash-completion
firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16
firewall-offline-cmd --zone=trusted --add-source=169.254.169.1
# Multinode clusters require connectivity on both apiserver and etcd
firewall-offline-cmd --zone=public --add-port=6443/tcp
firewall-offline-cmd --zone=public --add-port=2379/tcp
firewall-offline-cmd --zone=public --add-port=2380/tcp

# Configure limits for cAdvisor and kubelet
cat > /etc/sysctl.d/99-microshift.conf <<EOF
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 16384
EOF

# Create a link to the default kubeconfig.
# Note that the /root directory may be a symlink to /var/roothome and the target
# directory may not exist, depending on the operating system.
if [ ! -f /root/.kube/config ] ; then
    mkdir -p "$(readlink -f /root)/.kube"
    ln -sf /var/lib/microshift/resources/kubeadmin/kubeconfig /root/.kube/config
fi

# Enable the MicroShift service
systemctl enable microshift
