# talos-kernel

Builds a Talos Linux kernel package with `amneziawg.ko` compiled and signed alongside it: the
module is signed by the same per-build key the kernel's `CONFIG_SYSTEM_TRUSTED_KEYRING` trusts, so
`sig_enforce` never needs to be disabled. See [kernel-signing.md](docs/kernel-signing.md) for the
mechanism and why lighter alternatives do not work.

[talos-installer](https://github.com/slipmesh/talos-installer) takes both images from a release of
this repository: the kernel for the installer, `amneziawg-pkg` for its `amneziawg` extension.

## How it works

siderolabs signs out-of-tree modules by compiling them against the output of the same BuildKit
stage that builds the kernel (`siderolabs/pkgs`' `kernel-build`), as their own `zfs` and
`gasket-driver` packages do. `patches/pkgs/amneziawg-pkg/pkg.yaml` does that for `amneziawg`,
overlaid onto a pinned `siderolabs/pkgs` checkout.

```text
versions.env                  every pin: Talos version, pkgs commit, AWG ref, registry
patches/pkgs/amneziawg-pkg/   overlaid onto the siderolabs/pkgs checkout; builds the module
                              against the kernel build and shares its signing key
docs/kernel-signing.md        the mechanism, and why the alternatives fail
build/                        (gitignored) the pkgs checkout
```

## Building

Needs Docker with `docker buildx`: `bldr`, siderolabs' build tool, is a BuildKit frontend that
podman and buildah cannot run. A build works on one `TARGET_ARCH` at a time and wants about 40G
free.

```sh
make print-config                  # resolved pins and image names
make check-pins                    # PKGS is what TALOS_VERSION was built from
make preflight                     # docker, buildx, git, curl, disk space
make kernel TARGET_ARCH=amd64      # build and push the kernel and amneziawg-pkg for this arch
make kernel TARGET_ARCH=arm64      # the other arch, natively or under QEMU
make manifest                      # combine both arches into multi-arch tags
```

Images go to `REGISTRY` (default `ghcr.io/slipmesh`) as `kernel` and `amneziawg-pkg`, tagged
`TAG`, by default `sha-<HEAD commit>`, per arch as `<TAG>-<arch>`. `PUSH=false` builds without
pushing.

## CI and releases

Every pull request and every push to `main` or a `release-*` branch builds both images for both
arches, each on a runner of its own arch, unless it changes only Markdown, which is in no image. A
push to `main` or `release-*` publishes them as `sha-<commit>` and merges the arches.

A release builds nothing: it retags the `sha-<commit>` images of the commit it was cut from. See
[RELEASING.md](docs/RELEASING.md).

## Pinning

A module built against the wrong kernel carries the wrong `vermagic` and does not load. Talos
declares which pkgs it was built from, so the pkgs pin follows from the Talos version:

```sh
curl https://raw.githubusercontent.com/siderolabs/talos/$TALOS_VERSION/pkg/machinery/gendata/data/pkgs
```

`PKGS` holds that string verbatim, upstream's own notation, and `make check-pins` asserts the two
match. Not the plain `vX.Y.Z` pkgs tag: upstream tags pkgs once per minor Talos release and keeps
committing afterwards, so for `v1.14.0` the tag carries Linux 6.18.44 while Talos ships 6.18.48.

`PKGS_COMMIT` is the abbreviated object id off its tail. An abbreviated id cannot be fetched, only
resolved, so `checkout-pkgs` reaches for the network only when it does not resolve yet.

## Bumping

- **Talos:** set `TALOS_VERSION` and `PKGS` to what the command under "Pinning" returns, then
  `make check-pins`.
- **AmneziaWG:** set `AWG_REF`, run `make hashes` and paste both values back. The kernel is always
  rebuilt with the module: there is no way to rebuild only the module and keep the signing key.

Then release, and set `KERNEL_RELEASE` in talos-installer to the new tag.

## License

This repository's own code is MIT or Apache-2.0. The images it builds carry the Linux kernel and
the AmneziaWG module, both GPL-2.0; the module's license text ships inside `amneziawg-pkg`.
