# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [0.1.3+talos1.13.9] - 2026-08-27

### Added ✨

- Build AmneziaWG 3.1

### Documentation 📚

- Say why the pkgs pin is a commit and not a tag
- State the pkgs tagging rule without dating it

### Miscellaneous 🧹

- Move markdownlint config to the cli2 file

## [0.1.2+talos1.13.9] - 2026-08-26

### CI/CD ⚙️

- Pin amd64 matrix runner to ubuntu-24.04, not the floating ubuntu-latest alias

### Documentation 📚

- Update stale v1.13.8 example refs to v1.13.9
- Address the reader who cloned one repository, not five
- State the facts, drop how they were found
- Scope the QEMU note to local builds

### Miscellaneous 🧹

- Add the standard markdownlint config, fix what it found

## [0.1.1+talos1.13.9] - 2026-08-19

### Fixed 🐛

- Bump to Talos 1.13.9, pull AWG use-after-free fix

## [0.1.0+talos1.13.8] - 2026-08-18

### Added ✨

- Initial commit: split out of talos-awg-extension

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and release CI
- Tag releases like the bird repo: git release tag = published image tag

### Documentation 📚

- Document the fifth repo (talos-nftables-extension) in the split pipeline

### Fixed 🐛

- Split kernel build into per-arch native-runner jobs, avoid QEMU timeout
