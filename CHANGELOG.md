# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-13

### Changed

- `github.com/3leaps/yamlprims` is now v0.2.1 (was v0.1.1). The YAML loader
  canondocs uses behaves the same; canonical output is unchanged.
- Release tooling: the CI-artifact download requires the recorded ceremony
  anchor (absolute path outside the repository, no symlink, exact tag, object
  and commit bytes); without a named run it selects the single successful
  push-triggered release run for the tag at the tagged commit and refuses
  ambiguous, incomplete or malformed run listings; it reads only
  `CANONDOCS_RELEASE_RUN_ID` and `CANONDOCS_RELEASE_RUN_ATTEMPT` and refuses
  when an unprefixed `RELEASE_RUN_ID` or `RELEASE_RUN_ATTEMPT` is set.
- Release checklist: the Homebrew formula shape the tap accepts; the
  tag-protection check documents its three tag patterns.

## [0.1.0] - 2026-11-12

### Added

- `canondocs jcs`: RFC 8785 canonical bytes, `--digest` and `--vector` for
  JSON, YAML and NDJSON input; `--check` for JSON input; `--ndjson-array` /
  `--head` prefix cuts; `--sort-set` canonical sets; `--allow-merge-keys`;
  input limits.
- YAML to I-JSON projection with six fail-closed rules and conformance
  vectors in `testdata/yaml-jcs-rfc8785-v0`.
- `canondocs info`, `canondocs version [--json]` and `canondocs doctor`.
- Release tooling: read-only, digest-pinned CI and tag workflows; signed
  checksum manifests; tagged-commit public-key staging; published-release and
  Homebrew/Scoop/Go-proxy registry verification; each with a test suite.

[Unreleased]: https://github.com/3leaps/canondocs/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/3leaps/canondocs/releases/tag/v0.1.1
[0.1.0]: https://github.com/3leaps/canondocs/releases/tag/v0.1.0
