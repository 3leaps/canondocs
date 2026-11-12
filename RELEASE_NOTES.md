# Release Notes

The latest three releases, newest first. The complete history is in
[CHANGELOG.md](CHANGELOG.md); the notes for each release are in
[docs/releases/](docs/releases/).

---

## [0.1.0] - 2026-11-12

First release: a single static binary that writes RFC 8785 (JCS) canonical
JSON, `sha256:` digests and golden vector records from JSON, YAML 1.2 Core or
NDJSON input, with no runtime dependencies, network calls or state.

- `canondocs jcs` with `--check`, `--digest` and `--vector`; `--ndjson-array
  [--head N]` prefix cuts; `--sort-set` canonical sets; fail-closed YAML
  projection (`--allow-merge-keys` to apply `<<`); input limits.
- `canondocs info`, `canondocs version [--json]` and `canondocs doctor`.
- Signed release tag and checksum manifests; Homebrew tap, Scoop bucket and
  `go install` distribution.

Details: [docs/releases/v0.1.0.md](docs/releases/v0.1.0.md).
