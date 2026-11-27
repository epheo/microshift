#!/bin/bash
# The default Pool's volume group from the console installer's plan: when it
# lays the data disks out as one thin pool, this runs the README's recipe on
# them, once, before microshift-r-drbd-default-pool declares the Pool.
# A plan of another layout belongs to the image that asked for it (stornas
# mirrors pairs itself), and a volume group already named myvg1 is left as
# it is, unless it is this unit's own, left bare by a start that stopped.
set -euo pipefail

PLAN=/etc/amorce/data-disks.json
VG=myvg1
THIN=thin
DONE=/var/lib/microshift-r-drbd/data-disks-built

built() { mkdir -p "$(dirname "${DONE}")" && touch "${DONE}"; }

layout="$(jq -r '.layout // "pairs"' "${PLAN}")"
if [ "${layout}" != thin ]; then
    echo "plan layout ${layout}: not this unit's"
    exit 0
fi
mapfile -t devices < <(jq -r '.pools[].devices[]' "${PLAN}")
if [ "${#devices[@]}" = 0 ]; then
    echo "no data disks in the plan"
    built
    exit 0
fi
# Slow HBAs and USB bridges add their by-id links after local-fs.target.
# Without them, no marker: the next start tries again.
deadline=$((SECONDS + 60))
for d in "${devices[@]}"; do
    while [ ! -e "${d}" ] && [ "${SECONDS}" -lt "${deadline}" ]; do sleep 1; done
    if [ ! -e "${d}" ]; then
        echo "${d} is not there: trying again at the next start"
        exit 1
    fi
done
if vgs "${VG}" >/dev/null 2>&1; then
    # A start that stopped between vgcreate and lvcreate left the group
    # bare: finish it when it holds exactly the plan's disks and no volume.
    have="$(pvs --noheadings -o pv_name -S "vg_name=${VG}" | xargs -r -n1 readlink -f | sort)"
    want="$(printf '%s\n' "${devices[@]}" | xargs -r -n1 readlink -f | sort)"
    if [ "${have}" = "${want}" ] && [ "$(lvs --noheadings -o lv_name "${VG}" | wc -l)" = 0 ]; then
        echo "${VG} holds the plan's disks and no volume: making its thin pool"
        lvcreate --type thin-pool -l 90%FREE -n "${THIN}" "${VG}"
    else
        echo "${VG} exists: left as it is"
    fi
    built
    exit 0
fi
# vgcreate refuses a disk holding a signature: the installer wiped them, so
# one found here was claimed since, and stays untouched.
vgcreate "${VG}" "${devices[@]}"
lvcreate --type thin-pool -l 90%FREE -n "${THIN}" "${VG}"
built
