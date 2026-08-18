# talos-kernel

Builds a Talos Linux kernel package with `amneziawg.ko` compiled and signed alongside it
- the module gets signed by the same per-build key the running kernel's own
`CONFIG_SYSTEM_TRUSTED_KEYRING` trusts, so `sig_enforce` never needs to be disabled. See
`docs/kernel-signing.md` for the full mechanism and why lighter alternatives don't work.

## How it works

siderolabs already has a sanctioned way to sign an out-of-tree kernel module: compile it
*inside* the same BuildKit session that builds the kernel package itself
(`siderolabs/pkgs`'s `kernel-build` stage), the same pattern their own `zfs` and
`gasket-driver` packages use. `patches/pkgs/amneziawg-pkg/pkg.yaml` does exactly that for
`amneziawg`, overlaid onto a pinned `siderolabs/pkgs` checkout.

```
versions.env                  every pin: Talos version, pkgs commit, AWG ref
patches/pkgs/amneziawg-pkg/   overlaid onto a siderolabs/pkgs checkout - builds the
                               module alongside the kernel, shares its signing key
docs/kernel-signing.md        the full mechanism: why this works, why alternatives don't
build/                        (gitignored) the pkgs checkout
```

Needs **Docker** (`docker buildx`) - `bldr`, siderolabs' real build tool, is a custom
BuildKit frontend podman/buildah can't run.

## This is one of five repos

```
talos-kernel              (this repo)   -> signed kernel + amneziawg-pkg
talos-awg-extension                     -> amneziawg system extension (pulls amneziawg-pkg)
talos-router-extension                  -> router system extension (no kernel dependency)
talos-nftables-extension                -> nftables system extension (no kernel dependency)
talos-installer                         -> assembles kernel + N extensions into an installer
```

Each repo builds and publishes independently - none of them check out or depend on each
other's source, only on each other's published OCI tags. Like `../bird`, this repo's own
git release tag *is* the published image tag (see "Usage"/`RELEASE_TAG` below), so
consumers name a specific release rather than reconstructing a tag from shared pins:
`talos-awg-extension` pins the exact release it consumes via its own `versions.env`'s
`KERNEL_RELEASE`, and `talos-installer` takes a concrete `KERNEL_IMAGE` ref per invocation.
Bump `TALOS_VERSION`/`AWG_REF` here and in `talos-awg-extension`'s `versions.env` together
regardless - they still feed both repos' extension manifests (see `EXT_VERSION` in each
Makefile), even though they no longer construct the registry tag.

## Usage

`kernel`/`print-config` need `RELEASE_TAG=<the git tag being released>` (no default).
Like `../bird`, `RELEASE_TAG` *is* the published image tag (`+` swapped for `-`, since OCI
tags can't contain `+`) - see `cliff.toml`'s `tag_pattern` for the exact shape
(`vX.Y.Z[+talosA.B.C]`).

`kernel` also needs `TARGET_ARCH=amd64|arm64` - it builds and pushes one arch at a time
(`kernel:<tag>-<arch>`, `amneziawg-pkg:<tag>-<arch>`), then `merge` combines both into the
final tags nothing-arch-specific consumers use. A single multi-platform
(`linux/amd64,linux/arm64`) invocation used to cover both in one go, but the arm64 half
compiling under QEMU emulation blew GitHub Actions' 6h job timeout on the first real tag
push - see the Makefile's own comment on `merge` and `.github/workflows/release.yml`
(native `ubuntu-24.04-arm` runner for the arm64 leg instead).

```sh
make print-config RELEASE_TAG=v0.1.0+talos1.13.8 TARGET_ARCH=amd64   # resolved pins, image names
make preflight                                                         # docker/buildx/git/curl present, >=40G free
make kernel RELEASE_TAG=v0.1.0+talos1.13.8 TARGET_ARCH=amd64              # this arch: kernel + module, push both (~15-40 min)
make kernel RELEASE_TAG=v0.1.0+talos1.13.8 TARGET_ARCH=arm64              # the other arch
make merge RELEASE_TAG=v0.1.0+talos1.13.8                                    # combine both into the final multi-arch tags
```

## Pinning

A module built against the wrong kernel carries the wrong `vermagic` and will not load.
Talos declares which pkgs it was built from, so the pkgs pin is derivable:

```sh
curl https://raw.githubusercontent.com/siderolabs/talos/$TALOS_VERSION/pkg/machinery/gendata/data/pkgs
```

For `v1.13.8` that is `v1.13.0-55-gf677246` - commit `f677246`. `make check-pins` asserts
this.

## Bumping

**Talos:** set `TALOS_VERSION`, update `UPSTREAM_PKGS_REF` to whatever the command under
"Pinning" returns, `make check-pins`, then `make distclean && make kernel
RELEASE_TAG=<new release tag>`.

**AmneziaWG:** set `AWG_REF`, run `make hashes`, paste both values back, `make kernel
RELEASE_TAG=<new release tag>` (always rebuilds both together - there's no way to rebuild
only the module and keep the kernel half from the shared build, by design, see
`docs/kernel-signing.md`).

After bumping either, update `TALOS_VERSION`/`AWG_REF` in `talos-awg-extension`'s own
`versions.env` to match (still an informational cross-check there, folded into
`EXT_VERSION`), and set its `KERNEL_RELEASE` to this repo's new release tag - that's what
actually points it at the new `amneziawg-pkg` image. Give `talos-installer` the new
`KERNEL_IMAGE` ref directly when you next run it.
