#!/bin/bash
# Write the CRDs OVN-Kubernetes watches (MultiNetworkPolicy,
# AdminNetworkPolicy, BaselineAdminNetworkPolicy, EgressFirewall, IPAMClaim,
# UserDefinedNetwork, ClusterUserDefinedNetwork) into MicroShift's
# assets/crd/, taken from the OKD payload's cluster-network-operator, so they
# always match the OVN-Kubernetes that ships next to them.
# patches/0010 to 0013 list these files in pkg/assets/crd.go, which applies
# them before OVN-Kubernetes starts: it fails its informer sync without them.
#
# Usage: payload-crds.sh OKD_URL RELEASE_TAG MICROSHIFT_ROOT
set -euo pipefail

okd_url=$1
tag=$2
root=$3
yq="${root}/_output/bin/yq"
[ -x "${yq}" ] || "${root}/scripts/fetch_tools.sh" yq

# quay's CDN drops blobs mid-transfer (unexpected EOF) under CI load.
retry() {
    local i
    for i in 1 2 3 4; do
        "$@" && return 0
        [ "${i}" = 4 ] || { echo "retrying in 15s: $1 $2" >&2; sleep 15; }
    done
    return 1
}

cno="$(retry oc adm release info --image-for=cluster-network-operator "${okd_url}:${tag}")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
retry oc image extract "${cno}" \
    --path "/bindata/network/ovn-kubernetes/common/001-crd.yaml:${work}" \
    --path "/bindata/network/multus-networkpolicy/001-scheme.yaml:${work}"

# The operator renders 001-crd.yaml as a template. Its directives are if/end
# pairs around features this distribution leaves off (EVPN, route
# advertisements, network connect), some inside the CUDN CRD, so rendering
# drops those blocks and the column-0 comments about them. Any other
# directive fails the build rather than ship a half-rendered CRD.
render() {
    awk '
        /^\{\{-? *if / { depth++; next }
        /^\{\{-? *end *-?\}\}/ && depth { depth--; next }
        depth == 0 && !/^#/ { print }
    ' "$1" > "$1.rendered"
    if grep -n '{{' "$1.rendered" >&2; then
        echo "ERROR: $1 holds template directives besides if/end" >&2
        exit 1
    fi
    mv "$1.rendered" "$1"
}
render "${work}/001-crd.yaml"

# crd SOURCE NAME DEST: the one CRD called NAME, from SOURCE to DEST.
# Documents are split as text and only the selected one is parsed, to check it.
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
crd 001-crd.yaml egressfirewalls.k8s.ovn.org egressfirewall.crd.yaml
crd 001-crd.yaml ipamclaims.k8s.cni.cncf.io ipamclaims.crd.yaml
crd 001-crd.yaml userdefinednetworks.k8s.ovn.org userdefinednetwork.crd.yaml
crd 001-crd.yaml clusteruserdefinednetworks.k8s.ovn.org clusteruserdefinednetwork.crd.yaml
