# Builds a Talos kernel package with amneziawg.ko compiled and signed alongside it, the
# way siderolabs builds their own out-of-tree modules (zfs, gasket-driver): the module is
# compiled *inside* the same buildkit session as the kernel itself (siderolabs/pkgs'
# `kernel-build` stage), so both get signed by the one signing key that build generates -
# no persistent PKI of our own, no MOK, no `sig_enforce=0` workaround anywhere downstream.
# See docs/kernel-signing.md for the full mechanism and why a lighter "just swap the
# kernel" approach doesn't work.
#
# Needs Docker + `docker buildx` (siderolabs' real `bldr` toolchain, a custom BuildKit
# frontend podman/buildah can't run).
#
# This is the base of a five-repo pipeline: this repo publishes a signed kernel+module,
# talos-awg-extension, talos-router-extension, and talos-nftables-extension each package
# one system extension against it, talos-installer assembles a kernel + N extensions into
# what nodes actually boot.
# Each repo builds and publishes independently; nothing here checks out or depends on the
# others - see each repo's own README for how they're wired together by tag.
#
# build/ is disposable: `make distclean && make kernel` reproduces it from versions.env
# and patches/ alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(RELEASE_TAG),)
  ifneq ($(filter-out distclean help hashes checkout-pkgs check-pins preflight,$(_GOALS)),)
    $(error RELEASE_TAG not set - pass RELEASE_TAG=v0.1.0+talos1.13.8, the git tag this build is released under)
  endif
endif

BUILD_DIR := build
PKGS_DIR  := $(BUILD_DIR)/pkgs

AWG_SHORT := $(shell printf '%.7s' '$(AWG_REF)')

# Registry tags follow ../bird's own convention: the git release tag *is* the image tag
# (`+` swapped for `-`, since OCI tags can't contain `+`) - RELEASE_TAG is required, not
# derived from TALOS_VERSION/AWG_REF, so a rebuild against unchanged pins still needs an
# explicit new release to publish under. One repo per artifact, matching upstream's own
# convention (ghcr.io/siderolabs/kernel, ghcr.io/siderolabs/zfs-pkg, ...) -
# siderolabs/extensions' pkg.yaml templates expect exactly this shape
# ({{ .BUILD_ARG_PKGS_PREFIX }}/<name>:{{ .BUILD_ARG_PKGS }}), and talos-installer's
# PKG_KERNEL expects a plain image ref.
RELEASE_TAG_SAFE     := $(subst +,-,$(RELEASE_TAG))
KERNEL_IMAGE         := $(DOCKER_NS)/kernel:$(RELEASE_TAG_SAFE)
AMNEZIAWG_PKG_IMAGE  := $(DOCKER_NS)/amneziawg-pkg:$(RELEASE_TAG_SAFE)

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved pins and image names.
	@echo "talos          : $(TALOS_VERSION)"
	@echo "pkgs ref       : $(UPSTREAM_PKGS_REF)"
	@echo "awg ref        : $(AWG_REF) ($(AWG_SHORT))"
	@echo "release tag    : $(RELEASE_TAG)"
	@echo "kernel image   : $(KERNEL_IMAGE)"
	@echo "amneziawg pkg  : $(AMNEZIAWG_PKG_IMAGE)"

.PHONY: check-pins
check-pins: ## Assert UPSTREAM_PKGS_REF is the pkgs Talos $(TALOS_VERSION) was built from.
	@want=$$(curl -sS --fail "https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs"); \
	echo "talos $(TALOS_VERSION) declares pkgs: $$want"; \
	short=$${want##*-g}; \
	case "$(UPSTREAM_PKGS_REF)" in \
	  $$short*) echo "UPSTREAM_PKGS_REF matches ($$short)";; \
	  *) echo "MISMATCH: $(UPSTREAM_PKGS_REF) does not start with $$short"; \
	     echo "the module would be built for the wrong kernel and silently fail to load"; \
	     exit 1;; \
	esac

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git curl; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	free=$$(df -BG --output=avail $(PWD) | tail -1 | tr -dc 0-9); \
	if [ "$$free" -lt 40 ]; then echo "LOW DISK: $${free}G here, want >=40G for a kernel build"; fail=1; fi; \
	echo "host $$(uname -m), $$(nproc) cores"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

$(BUILD_DIR):
	@mkdir -p $@

.PHONY: checkout-pkgs
checkout-pkgs: | $(BUILD_DIR) ## Fetch siderolabs/pkgs at the pinned commit, overlay patches/pkgs/.
	@if [ ! -d "$(PKGS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/pkgs"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/pkgs.git $(PKGS_DIR); \
	fi
	@git -C $(PKGS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_PKGS_REF) 2>/dev/null || git -C $(PKGS_DIR) fetch --quiet origin
	@git -C $(PKGS_DIR) checkout --quiet --force --detach $(UPSTREAM_PKGS_REF)
	@rm -rf $(PKGS_DIR)/amneziawg-pkg
	@cp -r patches/pkgs/amneziawg-pkg $(PKGS_DIR)/amneziawg-pkg

# kernel+amneziawg-pkg MUST be built back to back against the same warm buildx cache -
# that's the entire mechanism that gives them the same signing key (kbuild auto-generates
# certs/signing_key.pem into the kernel-build stage's output the first time `make` runs
# against it; amneziawg-pkg's `dependencies: [stage: kernel-build]` only sees the *same*
# key if BuildKit serves that stage from cache rather than re-running it, which produces a
# fresh random key). Don't insert a `docker builder prune`/`--no-cache` between these two,
# don't switch buildx builders between them, and don't run them from a script that might
# retry only one half. See docs/kernel-signing.md for the full explanation, verified
# against siderolabs/pkgs' own zfs/gasket-driver packages and bldr's source.
#
# bldr loads and validates every pkg.yaml in the checkout up front, regardless of which
# --target= is actually being built (confirmed the hard way: `docker-kernel` alone fails
# amneziawg-pkg's own sha256/sha512 length validation if those build-args are absent, even
# though the kernel target never references that package) - so both invocations get the
# same full AWG_ARGS, not just the one that actually consumes them.
AWG_ARGS := --build-arg=AWG_REF=$(AWG_REF) --build-arg=AWG_SHA256=$(AWG_SHA256) --build-arg=AWG_SHA512=$(AWG_SHA512)

.PHONY: kernel
kernel: checkout-pkgs ## Build the kernel + amneziawg module together (shared signing key), push both. Multi-platform (amd64+arm64) in one invocation.
	@echo "==> building $(KERNEL_IMAGE) (linux/amd64,linux/arm64)"
	@$(MAKE) -C $(PKGS_DIR) docker-kernel PLATFORM=linux/amd64,linux/arm64 \
	  TARGET_ARGS="--tag=$(KERNEL_IMAGE) --push=true $(AWG_ARGS)"
	@echo "==> building $(AMNEZIAWG_PKG_IMAGE) (linux/amd64,linux/arm64)"
	@$(MAKE) -C $(PKGS_DIR) docker-amneziawg-pkg PLATFORM=linux/amd64,linux/arm64 \
	  TARGET_ARGS="--tag=$(AMNEZIAWG_PKG_IMAGE) --push=true $(AWG_ARGS)"
	@echo
	@echo "published:"
	@echo "  $(KERNEL_IMAGE)"
	@echo "  $(AMNEZIAWG_PKG_IMAGE)"
	@echo "consumers (talos-awg-extension, talos-installer) need TALOS_VERSION=$(TALOS_VERSION) AWG_REF=$(AWG_REF) to match"

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute AWG_SHA256/AWG_SHA512 for the current AWG_REF.
	@tmp=$$(mktemp); \
	curl -sSL --fail "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/$(AWG_REF).tar.gz" -o "$$tmp"; \
	echo "AWG_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	echo "AWG_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	rm -f "$$tmp"

.PHONY: clean
clean: ## No separate build output to drop - kept for symmetry with the other repos.
	@true

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkout.
	@rm -rf $(BUILD_DIR)
