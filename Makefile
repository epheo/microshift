# epheo's build of MicroShift — build entry points.
#
# All pinned inputs live in versions.env. The build is a three-stage container
# chain; each stage only needs podman (rootless is fine for building, the
# smoke test needs root).
#
#   make srpm    clone upstream @ pin, apply patches, swap payload to OKD, build SRPM
#   make rpm     rebuild the SRPM into native el10 RPMs (stream10 buildroot)
#   make image   assemble the bootc OS image (OVN + multus + topolvm + portail)
#   make smoke   boot the image as a privileged container and assert the opinions
#   make vm-test qcow2 + QEMU boot, full assertion suite (the CI gate)
#   make vm-test-upgrade  the same suite after bootc switch from the last release
#   make version print the version string of the built RPMs
#   make clean   remove the intermediate and final images

include versions.env
export

PODMAN ?= podman
SUDO_PODMAN ?= sudo podman

SRPM_IMAGE := epheo-microshift-srpm
RPM_IMAGE  := epheo-microshift-rpm
DIST_IMAGE := epheo-microshift

.PHONY: all
all: srpm rpm image

.PHONY: srpm
srpm:
	$(PODMAN) build \
	    -t "$(SRPM_IMAGE)" \
	    --build-arg USHIFT_GIT_URL="$(USHIFT_GIT_URL)" \
	    --build-arg USHIFT_GITREF="$(USHIFT_GITREF)" \
	    --build-arg OKD_VERSION_TAG="$(OKD_VERSION_TAG)" \
	    --build-arg OKD_RELEASE_IMAGE="$(OKD_RELEASE_IMAGE)" \
	    -f packaging/srpm.Containerfile .

.PHONY: rpm
rpm:
	$(PODMAN) build \
	    -t "$(RPM_IMAGE)" \
	    --ulimit nofile=524288:524288 \
	    --build-arg BUILDROOT_IMAGE="$(BUILDROOT_IMAGE)" \
	    -f packaging/rpm.Containerfile .

.PHONY: image
image:
	$(PODMAN) build \
	    -t "$(DIST_IMAGE)" \
	    --ulimit nofile=524288:524288 \
	    --label microshift.ref="$(USHIFT_GITREF)" \
	    --label okd.version="$(OKD_VERSION_TAG)" \
	    --label epheo.rev="$(EPHEO_REV)" \
	    --label portail.image="$(PORTAIL_IMAGE)" \
	    --build-arg BOOTC_IMAGE_URL="$(BOOTC_IMAGE_URL)" \
	    --build-arg BOOTC_IMAGE_TAG="$(BOOTC_IMAGE_TAG)" \
	    --build-arg PORTAIL_IMAGE="$(PORTAIL_IMAGE)" \
	    -f packaging/bootc.Containerfile .

# Extract the version string stamped into the RPM build (used for image tags).
.PHONY: version
version:
	@$(PODMAN) run --rm "$(RPM_IMAGE)" cat /home/microshift/microshift/_output/rpmbuild/RPMS/version.txt

# Copy the built RPMs out of the stage-2 image into RPM_OUTDIR.
.PHONY: rpms-out
rpms-out:
	@outdir="$${RPM_OUTDIR:-$$(mktemp -d /tmp/epheo-microshift-rpms-XXXXXX)}" && \
	cid=$$($(PODMAN) create "$(RPM_IMAGE)") && \
	trap "$(PODMAN) rm -f $$cid >/dev/null" EXIT && \
	$(PODMAN) cp "$$cid:/home/microshift/microshift/_output/rpmbuild/RPMS/." "$$outdir" && \
	echo "RPMs are available in '$$outdir'"

.PHONY: smoke
smoke:
	DIST_IMAGE="$(DIST_IMAGE)" ./scripts/smoke-test.sh

# Full acceptance test: bootc-image-builder -> qcow2 -> QEMU boot, asserting
# the opinions plus bootc/greenboot behavior on a real boot. The CI gate.
.PHONY: vm-test
vm-test:
	DIST_IMAGE="$(DIST_IMAGE)" ./scripts/vm-test.sh

# The same suite on the update path every existing install takes: boot the
# previously published image, bootc switch to the candidate, reboot, assert.
# Skips cleanly when UPGRADE_FROM does not exist yet (first release, forks).
UPGRADE_FROM ?= ghcr.io/epheo/microshift:latest

.PHONY: vm-test-upgrade
vm-test-upgrade:
	DIST_IMAGE="$(DIST_IMAGE)" UPGRADE_FROM="$(UPGRADE_FROM)" ./scripts/vm-test.sh

.PHONY: smoke-clean
smoke-clean:
	DIST_IMAGE="$(DIST_IMAGE)" CLEAN=1 ./scripts/smoke-test.sh

.PHONY: clean
clean:
	$(PODMAN) rmi -f "$(DIST_IMAGE)" || true
	$(PODMAN) rmi -f "$(RPM_IMAGE)" || true
	$(PODMAN) rmi -f "$(SRPM_IMAGE)" || true
