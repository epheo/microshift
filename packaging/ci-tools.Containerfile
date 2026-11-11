# QEMU and dnsmasq for the VM lanes (scripts/lib-qemu.sh), from Fedora: CI
# takes nothing from the runner's Ubuntu packages. The tests run QEMU with
# -display none, so the core package without weak dependencies is enough.
FROM quay.io/fedora/fedora:latest
RUN dnf -y install --setopt=install_weak_deps=False qemu-system-x86-core dnsmasq && \
    dnf clean all
