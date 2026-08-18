#!/bin/bash
# Build-time (bootc stage): repair and then verify the SELinux module store,
# after every dnf transaction in the image.
#
# libsemanage commits a module install by renaming the store's 'active' aside,
# which overlayfs refuses with EXDEV while that directory still lives in a lower
# layer. It falls back to a non-atomic copy, which leaves 'active' in place, so
# the next semodule in that same layer dies renaming its sandbox over it
# ("Directory not empty") and its rollback hits the same wall. rpm scriptlet
# failures do not fail dnf (the macros even end in '|| :'), so the image ships
# regardless.
#
# 2026-08-17 (CI run 32001230472): microshift-selinux failed exactly that way,
# right after openvswitch-selinux-extra-policy took the EXDEV fallback. A fresh
# install still passed the whole suite, because bootc-image-builder labels /usr
# from the image's own file_contexts. After a bootc switch the booted policy
# could not resolve openvswitch_load_module_exec_t: ovs-ctl was denied execute
# on ovs-kmod-ctl, br-ex never appeared, and MicroShift crash-looped on
# "failed to validate OVS bridge: failed to find OVN gateway interface".
set -euo pipefail

# The modules this image must not ship without. Names come from the packages'
# own scriptlets (semodule -r openvswitch-custom, and the spec's
# %selinux_modules_uninstall microshift), not from the file names.
readonly REQUIRED=(microshift openvswitch-custom)

# Passed explicitly, as the packages' scriptlets do, rather than leaving semodule
# to read SELINUXTYPE out of /etc/selinux/config.
readonly TYPE=targeted

# Leftovers from a half-committed transaction. 'active' holds the last good
# state, so drop the sandbox and the stale backup rather than roll either
# forward. /var/lib/selinux is the el9 store root and is absent here, but the
# packages come from el9fdp, so clean it too.
#
# Called again before every semodule: 'active' is in a lower layer in this layer
# too, so the EXDEV fallback recurs and one commit can otherwise break the next.
clean_leftovers() {
    local d
    for d in /etc/selinux/targeted /var/lib/selinux/targeted; do
        rm -rf "${d}/tmp" "${d}/previous"
    done
}

clean_leftovers

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
loaded="$(semodule -s "${TYPE}" -l)"

# The macro installs at priority 200; hand-written scriptlets use the default
# 400 (the shipped store confirms: modules/200/microshift,
# modules/400/openvswitch-custom). Repairing at the wrong priority would mask
# every later update of the owning package, or survive its removal, so mirror
# the owner: <type>/ subtree -> 200, top level -> 400. Batched per priority:
# each semodule commit is one more trip through the non-atomic fallback.
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
    clean_leftovers
    semodule -N -s "${TYPE}" -X 200 -i "${missing200[@]}" \
        || echo "WARNING: semodule -X 200 -i failed" >&2
fi
if [ "${#missing400[@]}" -gt 0 ]; then
    clean_leftovers
    semodule -N -s "${TYPE}" -i "${missing400[@]}" \
        || echo "WARNING: semodule -i failed" >&2
fi

# Unconditional rebuild: libsemanage renames the module dirs into 'active'
# before it writes policy.NN, so a store with every name present but a stale
# policy binary is reachable — and invisible to the name checks above. -B
# regenerates /etc/selinux/targeted/policy/policy.NN from the store, which is
# what the kernel loads and what ostree merges on a bootc switch. A failure
# here is fatal: it is the same commit path a real repair depends on.
clean_leftovers
semodule -N -s "${TYPE}" -B

# The gate: names must be present now, whatever the installs above reported.
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
