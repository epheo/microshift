#!/bin/bash
# Storage out of the box: when this node has volume group myvg1 with a thin
# pool named thin, declare it as an r-drbd Pool and make r-drbd-local the
# default StorageClass. A node without that thin pool is left as it is: a
# node upgraded from TopoLVM (thick LVs in myvg1, no thin pool) keeps
# TopoLVM as its default until its volumes have moved and an admin creates
# the thin pool.
set -euo pipefail

VG=myvg1
THIN=thin
export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig

if ! lvs --noheadings -o segtype "${VG}/${THIN}" 2>/dev/null | grep -qw thin-pool; then
    echo "no thin pool ${VG}/${THIN}: no default Pool"
    exit 0
fi

node="$(cat /var/lib/microshift/.nodename 2>/dev/null || hostname)"

# The kustomizer applies r-drbd after MicroShift reports ready, with retries.
ok=false
for _ in $(seq 120); do
    if oc wait --for=condition=Established --timeout=5s crd/pools.r-drbd.io >/dev/null 2>&1 &&
            oc get storageclass r-drbd-local >/dev/null 2>&1; then
        ok=true
        break
    fi
    sleep 5
done
${ok} || { echo "r-drbd's CRDs and classes did not appear in 10m"; exit 1; }

if oc get pools -o jsonpath='{range .items[*]}{.spec.node} {.spec.vg}{"\n"}{end}' | grep -qx "${node} ${VG}"; then
    echo "a Pool for ${node} ${VG} exists"
else
    oc apply -f - <<POOL
apiVersion: r-drbd.io/v1alpha1
kind: Pool
metadata:
  name: ${node}-${VG}
spec:
  node: ${node}
  tier: default
  vg: ${VG}
  thinPool: ${THIN}
POOL
fi

oc annotate --overwrite storageclass r-drbd-local storageclass.kubernetes.io/is-default-class=true
if oc get storageclass topolvm-provisioner >/dev/null 2>&1; then
    oc annotate --overwrite storageclass topolvm-provisioner storageclass.kubernetes.io/is-default-class=false
fi
