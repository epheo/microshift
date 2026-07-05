# Stage 2 of 3: rebuild the SRPM into binary RPMs.
#
# The buildroot is CentOS Stream 10, producing native el10 RPMs that match the
# el10 bootc host (the upstream spec supports rhel>=10 and stream10 golang
# satisfies the spec's minimum). Adapted from microshift-io/microshift
# packaging/rpm.Containerfile, which uses a stream9 buildroot.
ARG BUILDROOT_IMAGE=quay.io/centos/centos:stream10

FROM localhost/epheo-microshift-srpm:latest AS srpm

FROM ${BUILDROOT_IMAGE}

RUN dnf install -y \
        --setopt=install_weak_deps=False \
        rpm-build which git cpio createrepo_c \
        gcc gettext golang jq make policycoreutils selinux-policy selinux-policy-devel systemd && \
    dnf clean all

# Fall back to fetching the exact Go toolchain if the distro golang is ever
# older than the spec's minimum (RHEL golang defaults GOTOOLCHAIN=local).
ENV GOTOOLCHAIN=auto

COPY --from=srpm /home/microshift/microshift/_output/rpmbuild/SRPMS/ /tmp/

ARG BUILDER_RPM_REPO_PATH=/home/microshift/microshift/_output/rpmbuild/

WORKDIR /tmp

# hadolint ignore=DL4006
RUN \
    echo "# Extract the MicroShift source code for the bootc builder stage" && \
    rpm2cpio ./microshift-*.src.rpm | cpio -idm && \
    mkdir -p /home/microshift/microshift && \
    tar xf ./microshift-*.tar.gz -C /home/microshift/microshift --strip-components=1 && \
    \
    echo "# Build the RPMs from the SRPM" && \
    rpmbuild --quiet --define 'microshift_variant community' --rebuild ./microshift-*.src.rpm && \
    \
    echo "# Move the RPMs and create the repository" && \
    mkdir -p ${BUILDER_RPM_REPO_PATH}/ && \
    rm -rf ${BUILDER_RPM_REPO_PATH}/RPMS && \
    mv /root/rpmbuild/RPMS ${BUILDER_RPM_REPO_PATH}/ && \
    mkdir -p ${BUILDER_RPM_REPO_PATH}/RPMS/srpms/ && \
    mv ./microshift-*.src.rpm ${BUILDER_RPM_REPO_PATH}/RPMS/srpms/ && \
    mv ./version.txt ${BUILDER_RPM_REPO_PATH}/RPMS/ && \
    createrepo_c ${BUILDER_RPM_REPO_PATH}/RPMS && \
    rm -rf /root/rpmbuild /tmp/* /root/.cache/go-build
