# Builds a Talos kernel package with amneziawg.ko compiled and signed alongside it, the way
# siderolabs builds their own out-of-tree modules (zfs, gasket-driver): the module is compiled
# against the output of the kernel's own `kernel-build` stage, so both carry the one signing key
# that build generates - no PKI of our own, no MOK, no `sig_enforce=0` downstream. See
# docs/kernel-signing.md.
#
# Needs Docker with `docker buildx`: bldr is a BuildKit frontend that podman and buildah cannot
# run. build/ is disposable; `make distclean && make kernel` reproduces it from versions.env and
# patches/ alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out help print-config check-pins check-version preflight checkout-pkgs manifest hashes clean distclean,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64)
  endif
endif

BUILD_DIR := build
PKGS_DIR  := $(BUILD_DIR)/pkgs

# The abbreviated object id off the tail of PKGS: resolves locally, never fetchable - the
# protocol serves full ids only. See checkout-pkgs.
PKGS_COMMIT := $(lastword $(subst -g, ,$(PKGS)))

# Every image is tagged with the commit it was built from; a release retags that image without
# rebuilding it. The <registry>/<name>:<tag> shape is what siderolabs/extensions' pkg.yaml
# templates expect.
TAG  ?= sha-$(shell git rev-parse HEAD 2>/dev/null)
PUSH ?= true
ARCHS := amd64 arm64

KERNEL_IMAGE        := $(REGISTRY)/kernel:$(TAG)
AMNEZIAWG_PKG_IMAGE := $(REGISTRY)/amneziawg-pkg:$(TAG)

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved pins and image names.
	@echo "talos          : $(TALOS_VERSION)"
	@echo "pkgs           : $(PKGS) (commit $(PKGS_COMMIT))"
	@echo "awg ref        : $(AWG_REF)"
	@echo "kernel image   : $(KERNEL_IMAGE)  (per-arch: -<arch>)"
	@echo "amneziawg pkg  : $(AMNEZIAWG_PKG_IMAGE)  (per-arch: -<arch>)"

.PHONY: check-pins
check-pins: ## Assert PKGS is the pkgs Talos $(TALOS_VERSION) was built from.
	@want=$$(curl -sS --fail "https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs"); \
	echo "talos $(TALOS_VERSION) declares pkgs: $$want"; \
	if [ "$(PKGS)" = "$$want" ]; then \
	  echo "PKGS matches"; \
	else \
	  echo "MISMATCH: PKGS is $(PKGS)"; \
	  echo "the module would be built for the wrong kernel and silently fail to load"; \
	  exit 1; \
	fi

.PHONY: check-version
check-version: ## Assert VERSION is a release of TALOS_VERSION, vX.Y.Z+sm.N.
	@[[ "$(VERSION)" =~ ^$(subst .,\.,$(TALOS_VERSION))\+sm\.[1-9][0-9]*$$ ]] \
	  || { echo "VERSION must be $(TALOS_VERSION)+sm.<N>, got '$(VERSION)'"; exit 1; }
	@echo "$(VERSION) releases Talos $(TALOS_VERSION)"

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

# An abbreviated id can't be fetched, only resolved, so reach for the network solely when it
# doesn't resolve yet - and resolve it explicitly, where git errors on an ambiguous or absent
# id rather than checking out something else.
.PHONY: checkout-pkgs
checkout-pkgs: | $(BUILD_DIR) ## Fetch siderolabs/pkgs at the pinned commit, overlay patches/pkgs/.
	@if [ ! -d "$(PKGS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/pkgs"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/pkgs.git $(PKGS_DIR); \
	fi
	@git -C $(PKGS_DIR) rev-parse --verify --quiet '$(PKGS_COMMIT)^{commit}' >/dev/null \
	  || git -C $(PKGS_DIR) fetch --quiet --filter=blob:none --tags origin
	@full=$$(git -C $(PKGS_DIR) rev-parse --verify '$(PKGS_COMMIT)^{commit}'); \
	  git -C $(PKGS_DIR) checkout --quiet --force --detach "$$full"
	@rm -rf $(PKGS_DIR)/amneziawg-pkg
	@cp -r patches/pkgs/amneziawg-pkg $(PKGS_DIR)/amneziawg-pkg

# The kernel and amneziawg-pkg share a signing key only because BuildKit serves the second
# build's `kernel-build` stage from the first one's cache; a re-run of that stage generates a
# fresh random key. Keep both builds back to back on one builder: no prune, no --no-cache, no
# builder switch or retry of one half between them. See docs/kernel-signing.md.
#
# bldr validates every pkg.yaml in the checkout whichever target it builds, so the kernel build
# needs the AWG build-args too.
AWG_ARGS := --build-arg=AWG_REF=$(AWG_REF) --build-arg=AWG_SHA256=$(AWG_SHA256) --build-arg=AWG_SHA512=$(AWG_SHA512)

.PHONY: kernel
kernel: checkout-pkgs ## Build the kernel and the amneziawg module together for this arch, push both.
	@echo "==> building $(KERNEL_IMAGE)-$(TARGET_ARCH)"
	@$(MAKE) -C $(PKGS_DIR) docker-kernel PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(KERNEL_IMAGE)-$(TARGET_ARCH) --push=$(PUSH) $(AWG_ARGS)"
	@echo "==> building $(AMNEZIAWG_PKG_IMAGE)-$(TARGET_ARCH)"
	@$(MAKE) -C $(PKGS_DIR) docker-amneziawg-pkg PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(AMNEZIAWG_PKG_IMAGE)-$(TARGET_ARCH) --push=$(PUSH) $(AWG_ARGS)"

# Under QEMU the arm64 half of a kernel build outlasts the 6h job limit, so each arch builds on a
# runner of its own and this combines them.
.PHONY: manifest
manifest: ## Combine both arches' pushed images into the multi-arch tags.
	@for image in $(KERNEL_IMAGE) $(AMNEZIAWG_PKG_IMAGE); do \
	  docker buildx imagetools create -t "$$image" $(foreach a,$(ARCHS),"$$image-$(a)"); \
	done

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute AWG_SHA256/AWG_SHA512 for the current AWG_REF.
	@tmp=$$(mktemp); \
	curl -sSL --fail "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/$(AWG_REF).tar.gz" -o "$$tmp"; \
	echo "AWG_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	echo "AWG_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	rm -f "$$tmp"

.PHONY: clean
clean: ## Nothing outside build/ to drop.
	@true

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkout.
	@rm -rf $(BUILD_DIR)
