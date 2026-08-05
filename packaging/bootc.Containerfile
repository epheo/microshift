# Stage 3 of 3: the bootc OS image — epheo's build of MicroShift.
#
# Opinions shipped by this distribution (vs the upstream/community defaults):
#   - OVN-Kubernetes is the CNI (microshift-networking), not kindnet, with
#     enable-multi-network patched in at the source (patches/0001) so OVN
#     secondary localnet networks work without any runtime ConfigMap hack.
#   - Multus is installed and enabled (microshift-multus ships the config.d
#     toggle and the cri-o default-network drop-in).
#   - TopoLVM replaces LVMS as the storage driver (community subpackage).
#   - Air-gapped by default: the full MicroShift payload (every ref in the
#     installed release-info JSONs) is embedded as a shared-blob OCI layout
#     and imported into cri-o's store at boot — first boot needs no registry.
#   - portail is the edge/ingress component: its image is embedded and
#     imported the same way. The openshift-router stays available (and
#     embedded) but sites are expected to set ingress Removed.
#   - greenboot health gating stays fully enabled: a broken update must roll
#     back on its own.
#
# Derived images (site/lab layers) may drop additional OCI archives + manifest
# lines under /usr/lib/embedded-images/ — the import service picks them up.
ARG BOOTC_IMAGE_URL=quay.io/centos-bootc/centos-bootc
ARG BOOTC_IMAGE_TAG=stream10

FROM localhost/epheo-microshift-rpm:latest AS builder

FROM ${BOOTC_IMAGE_URL}:${BOOTC_IMAGE_TAG}

ARG PORTAIL_IMAGE=ghcr.io/epheo/portail:0.1.17

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
        skopeo \
        jq && \
    ${REPO_CONFIG_SCRIPT} -delete && \
    rm -vf  ${REPO_CONFIG_SCRIPT} && \
    rm -rvf ${USHIFT_RPM_REPO_PATH} && \
    dnf clean all

# containers-common 6.x moved the default signature policy to
# /usr/share/containers/policy.json, but el10 cri-o searches only $HOME and
# /etc/containers, so without this copy EVERY image pull fails "no policy.json
# file found". A booted node hides the defect: store-resident and embedded
# images keep running and greenboot stays green until the first fresh pull
# (2026-07-28: took out all Always-pull pods and, via the CSI sidecars, every
# PVC-backed workload). vm-test catches it as node-never-Ready in a clean VM.
RUN test -f /etc/containers/policy.json || \
    cp /usr/share/containers/policy.json /etc/containers/policy.json

# Post-install configuration (firewall, sysctl limits, kubeconfig link,
# service enablement).
COPY --chmod=755 ./src/rpm/postinstall.sh ${USHIFT_POSTINSTALL_SCRIPT}
RUN ${USHIFT_POSTINSTALL_SCRIPT} && rm -vf "${USHIFT_POSTINSTALL_SCRIPT}"

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

COPY --chmod=755 ./src/embedded-images/import-embedded-images.sh /usr/bin/import-embedded-images.sh
COPY ./src/embedded-images/import-embedded-images.service /usr/lib/systemd/system/import-embedded-images.service
RUN systemctl enable import-embedded-images.service

# bootc#1682 workaround: keep the skopeo helper privileged under the update
# timer so hosts pulling from authenticated registries can auto-update —
# see the drop-in for details.
COPY ./src/bootc/bootc-fetch-apply-updates-keep-skopeo-root.conf \
     /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-keep-skopeo-root.conf

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

# Guard: a second kernel in the image breaks bootc install at deploy time —
# fail the build here instead.
RUN count="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | wc -l)" && \
    if [ "${count}" != "1" ]; then \
        echo "ERROR: expected exactly 1 kernel in /usr/lib/modules, found ${count}:"; \
        ls /usr/lib/modules; \
        exit 1; \
    fi

# Guard: last step, after every package operation — cri-o reads the signature
# policy from /etc/containers only, and a base or package bump that loses the
# file again must fail the build, not the node.
RUN test -f /etc/containers/policy.json
