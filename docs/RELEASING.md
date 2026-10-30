# Releasing

## Lines and versions

A release is named after the Talos release it builds for, plus a revision: `v1.14.5+sm.1`. The
revision starts at 1 for every Talos patch and counts releases against it. Images carry the same
tag with `+` as `-`, since OCI tags cannot hold a `+`.

Stable releases come only from `release-1.X` branches, one per Talos minor; `main` follows the next
minor. A change lands on `main` first and is cherry-picked to the release branches it applies to
(`git cherry-pick -x`, then a pull request into `release-1.X`). A line is supported while upstream
ships patches for it.

| Talos line | branch | status |
| --- | --- | --- |
| 1.14 | `release-1.14` | supported |

## Cutting a release

1. On the release branch, bump `TALOS_VERSION` and `PKGS` (see the README, "Bumping") through a
   pull request, if the release is for a new Talos patch.
2. Run Actions, then Release PR, on the release branch with the version, such as `v1.14.5+sm.1`.
   It refuses a version that does not name `TALOS_VERSION`.
3. The pull request it opens changes only `CHANGELOG.md`. A bot opened it, so its checks wait for
   Approve workflows to run; the merge does not need them. Merge it.
4. Only this push builds: the kernel and amneziawg-pkg for both arches, about two hours, pushed as
   `sha-<commit>`. Once the build succeeds, the commit is tagged, both images are retagged as
   `kernel:<version>` and `amneziawg-pkg:<version>` by digest, and the GitHub Release is created,
   marked latest when it is the newest stable release, and pre-release for an alpha or beta. A
   failed build leaves no tag, so the same version can be released again after the fix.

Every other pull request and push checks the pins and builds nothing.

Then set `KERNEL_RELEASE` in talos-installer's branch for the same line to the new tag.

## Branching a new line

Before the first release for a new Talos minor, branch `release-1.X` from `main` and add it to the
table above. Then tag the branch point on `main` as the next minor's `alpha.0`, for `release-1.15`:

```sh
git tag -a v1.16.0-alpha.0 -m v1.16.0-alpha.0 <branch point>
git push origin v1.16.0-alpha.0
```

The `release-1.X` tags are not reachable from `main`, so without it git-cliff would list everything
that line releases again in `main`'s next section. The tag releases nothing: CI runs on branch
pushes, not tags.

## Withdrawing a broken release

A published release stays: its image is pinned by digest elsewhere, and a deleted tag would be
reused by the next run of the same version.

1. Put a warning at the top of its GitHub Release notes naming the release that replaces it.
2. Fix forward: the fix lands like any other change and is released as the next `+sm.N`.
3. A replacement that `sort -V` ranks below the broken release, such as a return to an older Talos
   patch, does not become latest by itself. Mark it latest with `gh release edit <tag> --latest`.
