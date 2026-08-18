#!/bin/bash
# Build-time (bootc stage): repair and then verify the SELinux module store,
# after every dnf transaction in the image.
#
# libsemanage commits a module install by renaming the store's 'active' aside,
# which overlayfs refuses with EXDEV while that directory still lives in a lower
# layer. It falls back to a non-atomic copy, and the next semodule in the same
# layer dies on the half-committed state. rpm scriptlet failures do not fail dnf
# (the macros even end in '|| :'), so the image ships regardless.
#
# 2026-08-17 (CI run 32001230472): microshift-selinux failed exactly that way.
# A fresh install still passed the whole suite, because bootc-image-builder
# labels /usr from the image's own file_contexts. After a bootc switch the
# booted policy could not resolve openvswitch_load_module_exec_t: ovs-ctl was
# denied execute on ovs-kmod-ctl, br-ex never appeared, and MicroShift
# crash-looped on "failed to find OVN gateway interface".
#
# 2026-08-18 (CI run 32120246151): repairing in place is ALSO at overlayfs's
# mercy — on the runner's storage, libsemanage's own rm+mkdir of the sandbox
# over a lower-layer 'tmp' produced a non-empty directory and every transaction
# died with "Could not copy files to sandbox (File exists)"; local storage does
# not reproduce it. So no semodule transaction may ever touch the merged
# /etc/selinux/targeted. All surgery happens on a scratch copy created in this
# layer (pure upper: every rename is a plain same-fs rename), and the result is
# written back with overwriting copies only — never delete-then-recreate a
# directory, which is the exact operation overlay storage got wrong.
set -euo pipefail

# The modules this image must not ship without. Names come from the packages'
# own scriptlets (semodule -r openvswitch-custom, and the spec's
# %selinux_modules_uninstall microshift), not from the file names.
readonly REQUIRED=(microshift openvswitch-custom)

# Passed explicitly, as the packages' scriptlets do, rather than leaving semodule
# to read SELINUXTYPE out of /etc/selinux/config.
readonly TYPE=targeted
readonly STORE=/etc/selinux/${TYPE}

# Leftovers of half-committed transactions, from this layer or a lower one.
# 'active' holds the last good state, so drop the sandbox and the stale backup
# rather than roll either forward. Removal only — nothing recreates these
# paths, so the fragile whiteout+mkdir sequence never happens on them.
# /var/lib/selinux is the el9 store root and is absent here, but the packages
# come from el9fdp, so clean it too.
for d in "${STORE}" /var/lib/selinux/${TYPE}; do
    rm -rf "${d}/tmp" "${d}/previous"
done

# Scratch store: created in this layer, so it is pure upper-layer content and
# semodule transactions on it are ordinary filesystem operations.
scratch="$(mktemp -d /root/selinux-repair.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT
cp -a "${STORE}" "${scratch}/${TYPE}"

sem() { semodule -N -S "${scratch}" -s "${TYPE}" "$@"; }

# Policy packages land as <type>/<name>.pp[.bz2] when installed by the
# %selinux_modules_install macro (microshift), or as a type-less top-level file
# when installed by a hand-written scriptlet (openvswitch-custom.cil). Take only
# the targeted subtree and the top level: a package shipping mls/ and targeted/
# variants must not get its mls policy into the targeted store.
mapfile -t pps < <(find /usr/share/selinux/packages \
    -type f \( -name '*.pp' -o -name '*.pp.bz2' -o -name '*.cil' \) \
    \( -path "*/packages/${TYPE}/*" -o -not -path '*/packages/*/*' \) | sort)

if [ "${#pps[@]}" -eq 0 ]; then
    echo "ERROR: no policy packages under /usr/share/selinux/packages" >&2
    exit 1
fi

# One snapshot is enough to find the missing set: installing one module never
# unloads another.
loaded="$(sem -l)"

# The macro installs at priority 200; hand-written scriptlets use the default
# 400 (the shipped store confirms: modules/200/microshift,
# modules/400/openvswitch-custom). Repairing at the wrong priority would mask
# every later update of the owning package, or survive its removal, so mirror
# the owner: <type>/ subtree -> 200, top level -> 400.
missing200=()
missing400=()
for pp in "${pps[@]}"; do
    mod="$(basename "${pp}")"
    mod="${mod%.bz2}"
    mod="${mod%.pp}"
    mod="${mod%.cil}"
    grep -qx "${mod}" <<<"${loaded}" && continue
    echo "will repair dropped SELinux module ${mod} from ${pp}"
    case "${pp}" in
        */packages/"${TYPE}"/*) missing200+=("${pp}") ;;
        *)                      missing400+=("${pp}") ;;
    esac
done

# Best-effort: a broken third-party module must not fail the build here — only
# the REQUIRED assert below decides that. -N as the packages' own scriptlets
# use: commit the store, do not load into the kernel, which has no policy to
# reload in a build container.
if [ "${#missing200[@]}" -gt 0 ]; then
    sem -X 200 -i "${missing200[@]}" || echo "WARNING: semodule -X 200 -i failed" >&2
fi
if [ "${#missing400[@]}" -gt 0 ]; then
    sem -i "${missing400[@]}" || echo "WARNING: semodule -i failed" >&2
fi

# Unconditional rebuild: libsemanage renames the module dirs into 'active'
# before it writes policy.NN, so a store with every name present but a stale
# policy binary is reachable — and invisible to the name checks above. -B
# regenerates policy.NN from the store, which is what the kernel loads and what
# ostree merges on a bootc switch. A failure here is fatal: it is the same
# commit path a real repair depends on.
sem -B

# -S redirects only the store transaction; the final install still writes
# policy.NN and the contexts files into the real ${STORE} (their paths come
# from semanage.conf, which -S does not override). So the real policy binary
# is already rebuilt — write back only active/, the module store, so the
# deployed system's own semodule runs see the repaired module set. Overwrite
# only: semodule never removed anything in the scratch, and fresh module dirs
# are plain new directories, not the delete-then-recreate overlay hazard.
cp -a "${scratch}/${TYPE}/active/." "${STORE}/active/"

# The gate, against the real store (read-only, no transaction): names must be
# present now, whatever the installs above reported.
loaded="$(semodule -s "${TYPE}" -l)"
missing=()
for mod in "${REQUIRED[@]}"; do
    if ! grep -qx "${mod}" <<<"${loaded}"; then
        missing+=("${mod}")
    fi
done

if [ "${#missing[@]}" -ne 0 ]; then
    echo "ERROR: required SELinux modules are not in the store: ${missing[*]}" >&2
    echo "modules currently in the store:" >&2
    echo "${loaded}" >&2
    exit 1
fi

echo "SELinux module store OK: ${REQUIRED[*]}"
