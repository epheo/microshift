#!/bin/bash
# Write the policy CRDs OVN-Kubernetes watches (MultiNetworkPolicy,
# AdminNetworkPolicy, BaselineAdminNetworkPolicy) into MicroShift's
# assets/crd/, taken from the OKD payload's cluster-network-operator, so they
# always match the OVN-Kubernetes that ships next to them.
# patches/0010 and 0011 list these files in pkg/assets/crd.go, which applies
# them before OVN-Kubernetes starts: it fails its informer sync without them.
#
# Usage: payload-crds.sh OKD_URL RELEASE_TAG MICROSHIFT_ROOT
set -euo pipefail

okd_url=$1
tag=$2
root=$3
yq="${root}/_output/bin/yq"
[ -x "${yq}" ] || "${root}/scripts/fetch_tools.sh" yq

cno="$(oc adm release info --image-for=cluster-network-operator "${okd_url}:${tag}")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
oc image extract "${cno}" \
    --path "/bindata/network/ovn-kubernetes/common/001-crd.yaml:${work}" \
    --path "/bindata/network/multus-networkpolicy/001-scheme.yaml:${work}"

# crd SOURCE NAME DEST: the one CRD called NAME, from SOURCE to DEST. The
# operator's bindata is a set of templates; other documents in the same file
# carry template directives yq cannot parse, so documents are split as text
# and only the selected one is parsed, to check it.
crd() {
    local src="${work}/$1" name=$2 dest="${root}/assets/crd/$3"
    {
        echo "# From ${cno} (${okd_url}:${tag}),"
        echo "# $1, written by src/image/payload-crds.sh."
        awk -v name="${name}" '
            /^---[[:space:]]*$/ { if (keep) printf "%s", doc; doc = ""; keep = 0; next }
            { doc = doc $0 "\n" }
            $0 == "  name: " name { keep = 1 }
            END { if (keep) printf "%s", doc }
        ' "${src}"
    } > "${dest}"
    if [ "$("${yq}" '.kind + " " + .metadata.name' "${dest}")" != "CustomResourceDefinition ${name}" ]; then
        echo "ERROR: CRD ${name} is not in the payload's cluster-network-operator $1" >&2
        exit 1
    fi
    echo "wrote ${dest} (${name})"
}

crd 001-scheme.yaml multi-networkpolicies.k8s.cni.cncf.io multi-networkpolicy.crd.yaml
crd 001-crd.yaml adminnetworkpolicies.policy.networking.k8s.io admin-network-policy.crd.yaml
crd 001-crd.yaml baselineadminnetworkpolicies.policy.networking.k8s.io baseline-admin-network-policy.crd.yaml
