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
3. The pull request it opens changes only `CHANGELOG.md`, so it runs no build. Merge it.
4. The push tags the release commit, retags the `sha-<commit>` images of the commit it was cut
   from as `kernel:<version>` and `amneziawg-pkg:<version>`, and creates the GitHub Release, not
   marked latest. Nothing is built, so this takes minutes.

Then set `KERNEL_RELEASE` in talos-installer's branch for the same line to the new tag.

## Branching a new line

Before the first release for a new Talos minor, branch `release-1.X` from `main` and add it to the
table above.
