# Stage 3 of 3: the bootc OS image — epheo's build of MicroShift.
#
# Opinions shipped by this distribution (vs the upstream/community defaults):
#   - OVN-Kubernetes is the CNI (microshift-networking), not kindnet, with
#     enable-multi-network patched in at the source (patches/0001) so OVN
#     secondary localnet networks work without any runtime ConfigMap hack.
#   - Multus is installed and enabled (microshift-multus ships the config.d
#     toggle and the cri-o default-network drop-in).
#   - r-drbd (DRBD 9 on thin LVM) is the storage driver, with its DRBD module
#     built for the image kernel. A node with VG myvg1 and a thin pool named
#     thin gets a Pool and a default StorageClass by itself.
#   - Air-gapped by default: the full MicroShift payload (every ref in the
#     installed release-info JSONs) is embedded as a shared-blob OCI layout
#     and imported into cri-o's store at boot — first boot needs no registry.
#   - portail is the edge/ingress component: its image is embedded and
#     imported the same way, the router is Removed by default, and the
#     Gateway API experimental CRDs (TCPRoute, UDPRoute) are applied at boot.
#     The router image stays embedded so a site can turn it back on air-gapped.
#   - greenboot health gating stays fully enabled: a broken update must roll
#     back on its own.
#   - Node profiles: every image can be a controller (default) or a worker
#     (microshift-profile worker + microshift add-node --worker); workers hold
#     no signing keys (patches/0006, 0007).
#   - The controller leads updates and workers follow the image it booted
#     green, one node at a time and only while every r-drbd Volume is fully
#     replicated; no node retries an image greenboot rolled back.
#
# Derived images (site/lab layers) may drop additional OCI archives + manifest
# lines under /usr/lib/embedded-images/ — the import service picks them up.
ARG BOOTC_IMAGE_URL
ARG BOOTC_IMAGE_TAG
ARG RPM_IMAGE=localhost/epheo-microshift-rpm:latest

FROM ${RPM_IMAGE} AS builder

# DRBD 9 for r-drbd is not in CentOS repos: built here against the base's own
# kernel, so a base kernel bump rebuilds it. KDIR pins the kmp build to that
# kernel (the spec takes the build host's uname -r otherwise). No debuginfo:
# the debug-source scan finds nothing under %_builddir and fails rpmbuild.
FROM ${BOOTC_IMAGE_URL}:${BOOTC_IMAGE_TAG} AS drbd-kmod
ARG DRBD_VERSION
ARG DRBD_SHA256
COPY --chmod=755 ./src/rpm/base-compose.sh /tmp/base-compose.sh
RUN test -n "${DRBD_VERSION}" -a -n "${DRBD_SHA256}" && \
    kver="$(ls /usr/lib/modules)" && \
    /tmp/base-compose.sh add && \
    dnf -y install "kernel-devel-${kver}" gcc make rpm-build kernel-rpm-macros \
        redhat-rpm-config elfutils-libelf-devel patch diffutils perl-interpreter && \
    curl -fsSL --retry 3 -o /tmp/drbd.tar.gz \
        "https://pkg.linbit.com/downloads/drbd/9/drbd-${DRBD_VERSION}.tar.gz" && \
    echo "${DRBD_SHA256}  /tmp/drbd.tar.gz" | sha256sum -c - && \
    tar -C /tmp -xzf /tmp/drbd.tar.gz && \
    make -C "/tmp/drbd-${DRBD_VERSION}" kmp-rpm KDIR="/usr/src/kernels/${kver}" \
        RPMOPT='--define "debug_package %{nil}"'

FROM ${BOOTC_IMAGE_URL}:${BOOTC_IMAGE_TAG}

# Pinned in versions.env; the Makefile passes it.
ARG PORTAIL_IMAGE
RUN test -n "${PORTAIL_IMAGE}" || { echo "ERROR: PORTAIL_IMAGE must be set"; exit 1; }

ARG REPO_CONFIG_SCRIPT=/tmp/create_repos.sh
ARG USHIFT_POSTINSTALL_SCRIPT=/tmp/postinstall.sh
ARG USHIFT_RPM_REPO_PATH=/tmp/rpm-repo
ARG BUILDER_RPM_REPO_PATH=/home/microshift/microshift/_output/rpmbuild/RPMS
ARG BUILDER_RSHARED_SERVICE=/home/microshift/microshift/packaging/imagemode/systemd/microshift-make-rshared.service

# A bootc image must contain exactly one kernel (bootc install refuses
# "multiple subdirectories in usr/lib/modules"). Debug kernels have slipped in
# as weak-dependency resolutions of the package set below — exclude them from
# every dnf transaction in this image and in derived/site images.
RUN echo 'excludepkgs=kernel-debug*' >> /etc/dnf/dnf.conf

# Every dnf transaction below also sees the compose this base was built
# from, and none may downgrade a base package; the scripts say why.
COPY --chmod=755 ./src/rpm/base-rpms.sh ./src/rpm/base-compose.sh /tmp/
RUN /tmp/base-rpms.sh snapshot && /tmp/base-compose.sh add

# Install MicroShift with the OVN + multus + greenboot selection, and the
# DRBD module built above. Runtime dependencies (cri-o, openvswitch, ...) come
# from the public mirror.openshift.com dependencies repo configured by
# create_repos.sh. drbd-utils stays off the host: the r-drbd agent image
# carries its own, and the package's units would disconnect r-drbd's
# resources at shutdown.
COPY --chmod=755 ./src/rpm/create_repos.sh ${REPO_CONFIG_SCRIPT}
COPY --from=builder ${BUILDER_RPM_REPO_PATH} ${USHIFT_RPM_REPO_PATH}
COPY --from=drbd-kmod /root/rpmbuild/RPMS/ /tmp/drbd-kmod/
RUN ${REPO_CONFIG_SCRIPT} -create ${USHIFT_RPM_REPO_PATH} && \
    dnf install -y \
        microshift \
        microshift-release-info \
        microshift-selinux \
        microshift-networking \
        microshift-multus \
        microshift-multus-release-info \
        microshift-greenboot \
        /tmp/drbd-kmod/*/kmod-drbd-[0-9]*.rpm \
        skopeo \
        jq && \
    ${REPO_CONFIG_SCRIPT} -delete && \
    rm -vf  ${REPO_CONFIG_SCRIPT} && \
    rm -rvf ${USHIFT_RPM_REPO_PATH} /tmp/drbd-kmod && \
    dnf clean all

# OVN-K hard-fails without xt_CT/nft_compat (ovnkube-node's geneve NOTRACK
# rule) and the node never goes Ready. They live in kernel-modules-extra,
# which the base dropped once (July 2026) and ships again: install only when
# missing, then fail the build here rather than in a VM. An install against
# a repo kernel behind the base's pulls a second kernel; the one-kernel
# guard below catches that.
RUN has_mods() { \
        k="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -1)" && \
        [ -n "$(find "${k}" -name 'xt_CT.ko*' -print -quit)" ] && \
        [ -n "$(find "${k}" -name 'nft_compat.ko*' -print -quit)" ]; } && \
    if ! has_mods; then dnf -y install kernel-modules-extra && dnf clean all; fi && \
    has_mods || { echo "ERROR: xt_CT/nft_compat missing from the image kernel"; exit 1; }

# Red Hat client stack, useless on CentOS Stream: a Lightspeed registration
# nag on every login, insights-client-boot.service phoning home, and RHEL
# entitlement tooling. Nothing else requires these. Must stay above the
# SELinux store repair: rhc and insights-core-selinux drop policy modules.
RUN dnf -y remove \
        rhc \
        yggdrasil \
        yggdrasil-worker-package-manager \
        insights-client \
        insights-core \
        insights-core-selinux \
        subscription-manager \
        python3-subscription-manager-rhsm \
        libdnf-plugin-subscription-manager \
        subscription-manager-rhsm-certificates && \
    dnf clean all

# containers-common 6.x moved the default signature policy to
# /usr/share/containers/policy.json, but cri-o (an el9 build from the
# OpenShift dependencies mirror) searches only $HOME and
# /etc/containers, so without this copy EVERY image pull fails "no policy.json
# file found". A booted node hides the defect: store-resident and embedded
# images keep running and greenboot stays green until the first fresh pull
# (2026-07-28: took out all Always-pull pods and, via the CSI sidecars, every
# PVC-backed workload). vm-test catches it as node-never-Ready in a clean VM.
RUN test -f /etc/containers/policy.json || \
    cp /usr/share/containers/policy.json /etc/containers/policy.json
# Same for registries.d: policy.json requires sigstore signatures for the Red
# Hat registries, and without these files cri-o never looks them up and
# rejects every image from registry.redhat.io and registry.access.redhat.com
# (microshift-io 87a0789).
RUN mkdir -p /etc/containers/registries.d && \
    for f in /usr/share/containers/registries.d/*.yaml; do \
        [ -f "${f}" ] || continue; \
        dst="/etc/containers/registries.d/$(basename "${f}")"; \
        [ -f "${dst}" ] || cp "${f}" "${dst}"; \
    done

# Role-scoped firewalld services; postinstall bakes the controller baseline
# and microshift-profile switches roles post-deploy.
COPY ./src/firewall/microshift-controlplane.xml \
     ./src/firewall/microshift-node.xml \
     /usr/lib/firewalld/services/

# Post-install configuration (firewall, sysctl limits, kubeconfig link,
# service enablement).
COPY --chmod=755 ./src/rpm/postinstall.sh ${USHIFT_POSTINSTALL_SCRIPT}
RUN ${USHIFT_POSTINSTALL_SCRIPT} && rm -vf "${USHIFT_POSTINSTALL_SCRIPT}"
RUN /tmp/base-compose.sh remove && /tmp/base-rpms.sh check && \
    rm -vf /tmp/base-rpms.sh /tmp/base-compose.sh

# postinstall's dnf transaction above is the last one in this image (later
# stages only run skopeo/systemctl). overlayfs makes semodule non-atomic inside
# a build layer, and a scriptlet that fails there does not fail dnf, so the
# store has to be repaired and asserted in its own layer after every dnf.
COPY --chmod=755 ./src/selinux/repair-module-store.sh /tmp/repair-module-store.sh
RUN /tmp/repair-module-store.sh && rm -vf /tmp/repair-module-store.sh

# Node role selector: controller (default) or worker (multinode, patches/0006).
COPY --chmod=755 ./src/profiles/microshift-profile /usr/bin/microshift-profile

# Updates: the controller leads on bootc's own timer and publishes the image
# it booted green; workers follow that exact image, one node at a time.
# src/update/microshift-update says why.
COPY --chmod=755 ./src/update/microshift-update /usr/libexec/microshift-update
COPY ./src/update/microshift-update-publish.service \
     ./src/update/microshift-update-follow.service \
     ./src/update/microshift-update-follow.timer \
     /usr/lib/systemd/system/
COPY ./src/update/bootc-fetch-apply-updates.conf \
     /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/50-microshift-update.conf
COPY --chmod=755 ./src/update/greenboot-red.sh /etc/greenboot/red.d/50_microshift_update_rolled_back.sh
COPY ./src/update/manifests/ /usr/lib/microshift/manifests.d/010-microshift-update/
RUN systemctl enable microshift-update-publish.service microshift-update-follow.service \
        microshift-update-follow.timer

# r-drbd, the storage plane. Its manifests apply from manifests.d like the
# rest of the payload; its images are listed in a release-info JSON so the
# payload embed below carries them.
# - Storage modules load at boot, not on demand: the agent reports DRBD
#   unsupported while the module is absent. usermode_helper=disabled: SELinux
#   confines kernel-spawned helpers, each resync handler then exits 1 and DRBD
#   drops the fresh connection; the agent follows DRBD events itself.
# - The host's LVM must never scan DRBD devices or LVs: they may hold guest VGs.
# - Graceful node shutdown lets pods release their volumes first.
# - microshift-r-drbd-default-pool declares the Pool for VG myvg1 with thin
#   pool thin when it exists, and leaves any other node as it is.
RUN printf '%s\n' drbd drbd_transport_tcp dm-snapshot dm-thin-pool \
        > /usr/lib/modules-load.d/r-drbd.conf && \
    echo 'options drbd usermode_helper=disabled' > /usr/lib/modprobe.d/r-drbd.conf
COPY ./src/r-drbd/lvmlocal.conf /etc/lvm/lvmlocal.conf
COPY ./src/r-drbd/40-graceful-shutdown.yaml /etc/microshift/config.d/40-graceful-shutdown.yaml
COPY ./src/r-drbd/kustomization.yaml /usr/lib/microshift/manifests.d/000-r-drbd/kustomization.yaml
COPY ./src/r-drbd/base/ /usr/lib/microshift/manifests.d/000-r-drbd/base/
COPY ./src/r-drbd/release-r-drbd-x86_64.json /usr/share/microshift/release/release-r-drbd-x86_64.json
COPY --chmod=755 ./src/r-drbd/greenboot-check.sh /etc/greenboot/check/required.d/50_microshift_r_drbd_check.sh
COPY --chmod=755 ./src/r-drbd/default-pool.sh /usr/libexec/microshift-r-drbd-default-pool
COPY ./src/r-drbd/microshift-r-drbd-default-pool.service /usr/lib/systemd/system/microshift-r-drbd-default-pool.service
RUN systemctl enable microshift-r-drbd-default-pool.service

# Embed the full MicroShift payload under /usr/lib/embedded-images.
# import-embedded-images.service imports every manifest entry into cri-o's
# graphroot before MicroShift starts, so an air-gapped first boot works out
# of the box. The list is derived from the installed release-info JSONs at
# build time; a payload bump cannot silently reintroduce a first-boot pull.
COPY --chmod=755 ./src/embedded-images/embed-release-images.sh /tmp/embed-release-images.sh
RUN /tmp/embed-release-images.sh && rm -vf /tmp/embed-release-images.sh

# Embed the portail image as an OCI archive under /usr/lib/embedded-images.
# Kept as a separate archive (not the payload layout): site layers follow
# this exact tar + manifest-line pattern and it shares no blobs with the
# payload anyway. Workloads reference localhost/embedded/<name>:<tag> with
# imagePullPolicy: IfNotPresent.
RUN mkdir -p /usr/lib/embedded-images && \
    name="${PORTAIL_IMAGE##*/}" && \
    tar="/usr/lib/embedded-images/${name%%:*}.tar" && \
    skopeo copy --retry-times 3 \
        "docker://${PORTAIL_IMAGE}" "oci-archive:${tar}:localhost/embedded/${name}" && \
    echo "${tar} localhost/embedded/${name}" >> /usr/lib/embedded-images/manifest

COPY ./src/edge/00-ingress-removed.yaml /etc/microshift/config.d/00-ingress-removed.yaml

# MicroShift ships no Gateway API CRDs of its own (the OSSM subpackage that
# would is stripped by src/image/modify-spec.py). 000 sorts first among
# manifests.d kustomizations, which apply one at a time with a 10m retry each:
# a site's Gateways sorting before the CRDs would be skipped until next start.
ARG GATEWAY_API_VERSION
ARG GATEWAY_API_SHA256
COPY ./src/edge/gateway-api/kustomization.yaml /usr/lib/microshift/manifests.d/000-gateway-api/
RUN crds=/usr/lib/microshift/manifests.d/000-gateway-api/experimental-install.yaml && \
    curl -fsSL --retry 3 -o "${crds}" \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml" && \
    echo "${GATEWAY_API_SHA256}  ${crds}" | sha256sum -c -

# OpenShift's grants that MicroShift's apiserver bootstrap lacks (storage and
# snapshot classes for every signed-in user, Gateway API and NAD reads in the
# stock project roles), vendored from the pinned payload's sources by
# src/rbac/vendor.sh, plus this distribution's experimental route kinds.
COPY ./src/rbac/kustomization.yaml ./src/rbac/openshift-parity.yaml ./src/rbac/experimental-routes.yaml \
    /usr/lib/microshift/manifests.d/010-openshift-rbac/

COPY --chmod=755 ./src/embedded-images/import-embedded-images.sh /usr/bin/import-embedded-images.sh
COPY ./src/embedded-images/import-embedded-images.service /usr/lib/systemd/system/import-embedded-images.service
RUN systemctl enable import-embedded-images.service

# kubelet sandbox creation hard-fails on open /etc/resolv.conf, and nothing
# in this image ships one: NetworkManager only writes it when DHCP hands out
# DNS servers, which an air-gapped site (or qemu restrict=on) never does.
# Not empty: coredns' "forward . /etc/resolv.conf" refuses to start on zero
# nameservers (dns-default crash-loops). 127.0.0.1 lets it start — cluster
# DNS works, upstream queries fail per-query, which is what air-gapped
# means; the Corefile has no loop plugin, so no self-forward crash. NM
# overwrites the file whenever it does have data. The trailing literal \n
# is a tmpfiles C-style escape.
RUN echo 'f /etc/resolv.conf 0644 root root - nameserver 127.0.0.1\n' \
        > /usr/lib/tmpfiles.d/microshift-resolv-conf.conf

# Recursively make the root filesystem subtree shared, as required by the OVN
# images (mount propagation).
COPY --from=builder ${BUILDER_RSHARED_SERVICE} /usr/lib/systemd/system/microshift-make-rshared.service
RUN systemctl enable microshift-make-rshared.service

# The /var directory is shared with the container as an anonymous volume to
# enable idmap mounts under /var/lib/kubelet (also lets the image run as a
# plain podman container for smoke tests).
VOLUME ["/var"]

RUN if systemctl list-unit-files bootc-publish-rhsm-facts.service >/dev/null 2>&1 ; then \
        systemctl disable bootc-publish-rhsm-facts.service ; \
    fi

# Base-image daemons a headless, air-gapped-by-default node has no use for.
# fwupd-refresh pulls LVFS metadata from the internet daily, and fwupd's bluez
# and UEFI plugins dbus-activate bluetoothd and udisksd along the way.
# Masked, not disabled: disable does not stop dbus activation.
RUN systemctl mask bluetooth.service fwupd-refresh.timer

# Guard: a second kernel in the image breaks bootc install at deploy time —
# fail the build here instead.
RUN count="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | wc -l)" && \
    if [ "${count}" != "1" ]; then \
        echo "ERROR: expected exactly 1 kernel in /usr/lib/modules, found ${count}:"; \
        ls /usr/lib/modules; \
        exit 1; \
    fi

# Guard: the DRBD module is the pinned version and built for the one kernel
# this image boots; TopoLVM did not come back through a dependency.
ARG DRBD_VERSION
RUN kver="$(ls /usr/lib/modules)" && \
    [ "$(modinfo -k "${kver}" -F version drbd)" = "${DRBD_VERSION}" ] && \
    modinfo -k "${kver}" -F vermagic drbd | grep -q "^${kver} " && \
    ! rpm -q microshift-topolvm drbd-utils

# Guard: last step, after every package operation — cri-o reads the signature
# policy from /etc/containers only, and a base or package bump that loses the
# file again must fail the build, not the node.
RUN test -f /etc/containers/policy.json && \
    test -f /etc/containers/registries.d/registry.redhat.io.yaml
