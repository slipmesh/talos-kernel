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
other's source, only on each other's published OCI tags (by convention: same
`TALOS_VERSION`/`AWG_REF` pins reconstruct the same tag this repo publishes under, see
`make print-config`). `talos-awg-extension` and `talos-installer` both need this repo's
`TALOS_VERSION`/`AWG_REF` values to match their own `versions.env` - bump them together.

## Usage

```sh
make print-config   # resolved pins, image names
make preflight       # docker/buildx/git/curl present, >=40G free
make kernel            # build kernel + amneziawg module together, push both (~15-40 min)
```

`make kernel` is arch-independent - one multi-platform (`linux/amd64,linux/arm64`)
`docker buildx` invocation covers both.

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
"Pinning" returns, `make check-pins`, then `make distclean && make kernel`.

**AmneziaWG:** set `AWG_REF`, run `make hashes`, paste both values back, `make kernel`
(always rebuilds both together - there's no way to rebuild only the module and keep the
kernel half from the shared build, by design, see `docs/kernel-signing.md`).

After bumping either, update `TALOS_VERSION`/`AWG_REF` to match in `talos-awg-extension`'s
and `talos-installer`'s own `versions.env`.
