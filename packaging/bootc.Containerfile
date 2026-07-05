# Stage 3 of 3: the bootc OS image — epheo's build of MicroShift.
#
# Opinions shipped by this distribution (vs the upstream/community defaults):
#   - OVN-Kubernetes is the CNI (microshift-networking), not kindnet, with
#     enable-multi-network patched in at the source (patches/0001) so OVN
#     secondary localnet networks work without any runtime ConfigMap hack.
#   - Multus is installed and enabled (microshift-multus ships the config.d
#     toggle and the cri-o default-network drop-in).
#   - TopoLVM replaces LVMS as the storage driver (community subpackage).
#   - portail is the edge/ingress component: its image is embedded as an OCI
#     archive and imported into cri-o's store at boot, so a cold boot needs no
#     registry. The openshift-router stays available but sites are expected to
#     set ingress Removed.
#   - greenboot health gating stays fully enabled: a broken update must roll
#     back on its own.
#
# Derived images (site/lab layers) may drop additional OCI archives + manifest
# lines under /usr/lib/embedded-images/ — the import service picks them up.
ARG BOOTC_IMAGE_URL=quay.io/centos-bootc/centos-bootc
ARG BOOTC_IMAGE_TAG=stream10

FROM localhost/epheo-microshift-rpm:latest AS builder

FROM ${BOOTC_IMAGE_URL}:${BOOTC_IMAGE_TAG}

ARG PORTAIL_IMAGE=ghcr.io/epheo/portail:0.1.16

ARG REPO_CONFIG_SCRIPT=/tmp/create_repos.sh
ARG USHIFT_POSTINSTALL_SCRIPT=/tmp/postinstall.sh
ARG USHIFT_RPM_REPO_PATH=/tmp/rpm-repo
ARG BUILDER_RPM_REPO_PATH=/home/microshift/microshift/_output/rpmbuild/RPMS
ARG BUILDER_RSHARED_SERVICE=/home/microshift/microshift/packaging/imagemode/systemd/microshift-make-rshared.service

# Install MicroShift with the OVN + multus + topolvm + greenboot selection.
# Runtime dependencies (cri-o, openvswitch, ...) come from the public
# mirror.openshift.com dependencies repo configured by create_repos.sh.
COPY --chmod=755 ./src/rpm/create_repos.sh ${REPO_CONFIG_SCRIPT}
COPY --from=builder ${BUILDER_RPM_REPO_PATH} ${USHIFT_RPM_REPO_PATH}
RUN ${REPO_CONFIG_SCRIPT} -create ${USHIFT_RPM_REPO_PATH} && \
    dnf install -y \
        microshift \
        microshift-release-info \
        microshift-selinux \
        microshift-networking \
        microshift-multus \
        microshift-multus-release-info \
        microshift-topolvm \
        microshift-topolvm-release-info \
        microshift-greenboot \
        skopeo && \
    ${REPO_CONFIG_SCRIPT} -delete && \
    rm -vf  ${REPO_CONFIG_SCRIPT} && \
    rm -rvf ${USHIFT_RPM_REPO_PATH} && \
    dnf clean all

# Post-install configuration (firewall, sysctl limits, kubeconfig link,
# service enablement).
COPY --chmod=755 ./src/rpm/postinstall.sh ${USHIFT_POSTINSTALL_SCRIPT}
RUN ${USHIFT_POSTINSTALL_SCRIPT} && rm -vf "${USHIFT_POSTINSTALL_SCRIPT}"

# Embed the portail image as an OCI archive under /usr/lib/embedded-images.
# import-embedded-images.service imports every archive listed in the manifest
# into cri-o's graphroot before MicroShift starts; manifests reference
# localhost/embedded/<name>:<tag> with imagePullPolicy: IfNotPresent.
RUN mkdir -p /usr/lib/embedded-images && \
    name="${PORTAIL_IMAGE##*/}" && \
    tar="/usr/lib/embedded-images/${name%%:*}.tar" && \
    skopeo copy --retry-times 3 \
        "docker://${PORTAIL_IMAGE}" "oci-archive:${tar}:localhost/embedded/${name}" && \
    echo "${tar} localhost/embedded/${name}" >> /usr/lib/embedded-images/manifest

COPY --chmod=755 ./src/embedded-images/import-embedded-images.sh /usr/bin/import-embedded-images.sh
COPY ./src/embedded-images/import-embedded-images.service /usr/lib/systemd/system/import-embedded-images.service
RUN systemctl enable import-embedded-images.service

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
