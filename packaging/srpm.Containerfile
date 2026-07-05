# Stage 1 of 3: source preparation and SRPM build.
#
# Clones openshift/microshift at the pinned ref, applies this distribution's
# patch series, swaps the pinned OCP payload images for the (fully public)
# OKD SCOS payload, merges the TopoLVM add-on subpackage into the spec, and
# builds the SRPM. Adapted from microshift-io/microshift packaging/srpm.Containerfile.
#
# x86_64 only: the aarch64 release JSONs keep their upstream (OCP) references —
# they are shipped in release-info for spec completeness but never consumed by
# the images we publish. This avoids depending on microshift-io's daily arm64
# OKD payload rebuilds.
FROM quay.io/fedora/fedora:latest

RUN dnf install -y \
        --setopt=install_weak_deps=False \
        git rpm-build jq python3-pip python3-specfile skopeo && \
    dnf clean all

ARG USHIFT_GIT_URL=https://github.com/openshift/microshift.git
ARG USHIFT_GITREF
ARG OKD_VERSION_TAG
ARG OKD_RELEASE_IMAGE=quay.io/okd/scos-release

ENV HOME=/home/microshift

RUN if [ -z "${USHIFT_GITREF}" ] || [ -z "${OKD_VERSION_TAG}" ]; then \
        echo "ERROR: USHIFT_GITREF and OKD_VERSION_TAG must be set"; \
        exit 1; \
    fi

# The oc client matching the OKD payload, used by prebuild.sh to read the
# release image references.
RUN curl -fsSL --retry 5 -o /tmp/okd-client.tar.gz \
        "https://github.com/okd-project/okd/releases/download/${OKD_VERSION_TAG}/openshift-client-linux-${OKD_VERSION_TAG}.tar.gz" && \
    tar -xzf /tmp/okd-client.tar.gz -C /usr/local/bin/ && \
    rm -f /tmp/okd-client.tar.gz

WORKDIR ${HOME}

RUN git clone --branch "${USHIFT_GITREF}" --single-branch --depth 1 \
        "${USHIFT_GIT_URL}" "${HOME}/microshift"

WORKDIR ${HOME}/microshift/

# The distribution's patch series: pristine upstream + patches/*.patch, kept
# minimal and rebased onto every new pinned ref.
COPY ./patches/ /tmp/patches/
RUN find /tmp/patches -name '*.patch' | sort | while read -r p; do \
        echo "Applying $(basename "${p}")" && git apply --stat --apply "${p}" || exit 1; \
    done

# Swap payload images to OKD (base components, OLM references, multus) and
# relax the networking hard dependency in the spec.
COPY --chmod=755 ./src/image/prebuild.sh /tmp/prebuild.sh
RUN ARCH="x86_64" /tmp/prebuild.sh --replace        "${OKD_RELEASE_IMAGE}" "${OKD_VERSION_TAG}" && \
    ARCH="x86_64" /tmp/prebuild.sh --replace-multus "${OKD_RELEASE_IMAGE}" "${OKD_VERSION_TAG}"

# Merge the TopoLVM subpackage (community LVMS replacement — the LVMS operator
# is not part of the OKD payload) and drop subpackages not buildable upstream.
ARG SPEC_TOPOLVM=/tmp/topolvm.spec
COPY ./src/topolvm/topolvm.spec "${SPEC_TOPOLVM}"
COPY ./src/topolvm/assets/  ./assets/optional/topolvm/
COPY ./src/topolvm/dropins/ ./packaging/microshift/dropins/
COPY ./src/topolvm/greenboot/ ./packaging/greenboot/
COPY ./src/topolvm/release/ ./assets/optional/topolvm/

COPY --chmod=755 ./src/image/modify-spec.py /tmp/modify-spec.py
RUN sed -i -e 's,CHECK_RPMS="y",,g' -e 's,CHECK_SRPMS="y",,g' ./packaging/rpm/make-rpm.sh && \
    /tmp/modify-spec.py ./packaging/rpm/microshift.spec "${SPEC_TOPOLVM}"

COPY --chmod=755 ./src/image/build-rpms.sh /tmp/build-rpms.sh
RUN USHIFT_GITREF="${USHIFT_GITREF}" OKD_VERSION_TAG="${OKD_VERSION_TAG}" \
        /tmp/build-rpms.sh srpm
