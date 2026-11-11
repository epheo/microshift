#!/bin/bash
# Build the ovnkube that this release's OVN-Kubernetes image runs, from the
# commit its labels name, plus the fixes in src/ovn/*.patch, in order:
#   0001 ovn-kubernetes #6735 (kubelet-cgroup-path): with network
#        segmentation on, the 5.0 ovnkube-node looks for a cgroup named
#        kubelet.service and exits; MicroShift's kubelet runs inside
#        microshift.service. OpenShift ships it from 5.1.
# patches/0016 mounts the result over /usr/bin/ovnkube in every OVN-K
# container that runs it, so all of them run one version.
#
# Temporary: once the payload's source has a fix, this script fails on
# purpose and names it. Delete that patch; with the last one, delete src/ovn/,
# the ovnkube stage in packaging/bootc.Containerfile and the
# microshift-ovnkube mounts in patches/0016, and keep [ovnkubenode]
# kubelet-cgroup-path.
#
# Usage: build-ovnkube.sh RELEASE_JSON OUT
set -euo pipefail

release_json=$1
out=$2
patches=("$(cd "$(dirname "$0")" && pwd)"/*.patch)

image="$(jq -er '.images["ovn-kubernetes-microshift"]' "${release_json}")"
labels="$(skopeo inspect --retry-times 3 --no-tags "docker://${image}" | jq .Labels)"
repo="$(jq -er '.["io.openshift.build.source-location"]' <<<"${labels}")"
commit="$(jq -er '.["io.openshift.build.commit.id"]' <<<"${labels}")"

src="$(mktemp -d)"
trap 'rm -rf "${src}"' EXIT
git -C "${src}" init -q
git -C "${src}" fetch -q --depth 1 "${repo}" "${commit}"
git -C "${src}" checkout -q FETCH_HEAD

for patch in "${patches[@]}"; do
    if git -C "${src}" apply --check "${patch}" 2>/dev/null; then
        git -C "${src}" apply "${patch}"
    elif git -C "${src}" apply --reverse --check "${patch}" 2>/dev/null; then
        echo "ERROR: ${repo}@${commit} has $(basename "${patch}") already: delete it," \
            "and with the last one src/ovn/, the ovnkube stage in" \
            "packaging/bootc.Containerfile and the microshift-ovnkube mounts" >&2
        exit 1
    else
        echo "ERROR: $(basename "${patch}") does not apply to ${repo}@${commit}" >&2
        git -C "${src}" apply --check "${patch}"
        exit 1
    fi
done
# The toolchain go.mod names, as upstream builds it: the builder's own Go can
# be newer than the vendored code allows (Go 1.27 turns jsonv2 on, which the
# vendored kube-openapi fails to compile against).
toolchain="$(sed -n 's/^toolchain //p' "${src}/go-controller/go.mod")"
(cd "${src}/go-controller" &&
    GOTOOLCHAIN="${toolchain:-auto}" CGO_ENABLED=0 \
        go build -mod=vendor -trimpath -ldflags "-s -w" -o "${out}" ./cmd/ovnkube)
echo "built ${out} from ${repo}@${commit} with ${patches[*]##*/}"
