# Release Checklist

Checklist for canondocs releases.

## Pre-Release

### Code Quality

- [ ] Format, vet, tests, content and workflow-pin checks: `make check`
- [ ] Public-surface hygiene: `make surface-scan`
- [ ] Release provenance and tooling suites: `make release-provenance-check` and `make release-tooling-test`
- [ ] Build-host path checks: `make host-path-check`
- [ ] Sensitive local data reviewed against the [3 Leaps Sensitive Local Data Policy](https://github.com/3leaps/oss-policies/blob/main/SENSITIVE-LOCAL-DATA.md); none is stored inside the repo tree relying only on `.gitignore`.
- [ ] Every release target builds: `make build-all`
- [ ] Smoke tests:
  - [ ] `./bin/canondocs version` and `./bin/canondocs version --json`
  - [ ] `./bin/canondocs doctor`
  - [ ] `./bin/canondocs info`

### Documentation

- [ ] `README.md` reviewed
- [ ] CLI help text accurate
- [ ] Release notes agree across the public surfaces:
  - [ ] `CHANGELOG.md` has a section for the release version
  - [ ] `RELEASE_NOTES.md` has the current release summary
  - [ ] `docs/releases/v<version>.md` exists, follows `docs/releases/TEMPLATE.md`
        (Release provenance and an Install section for this tag), and is the
        GitHub release body; `make release-preflight` refuses notes without
        install instructions for the tag

### Dependencies

- [ ] `go.mod` requires only `github.com/3leaps/canonprims` and `github.com/3leaps/yamlprims`, at published versions
- [ ] No local `replace` directives and no `go.work`
- [ ] `go mod tidy` leaves `go.mod` and `go.sum` unchanged
- [ ] `go.sum` lists no third-party modules

## Release Preparation

- [ ] Update `VERSION` and `Version` in `internal/cli/cli.go` (`go test ./...` checks they agree)
- [ ] Version sanity check: `CANONDOCS_RELEASE_TAG=v<version> make release-guard-signing-tag`
- [ ] All changes committed with attribution trailers; `git status` clean
- [ ] Fresh clone: `make build && make test`

## Release Execution

### Tagging (maintainer machine)

The tag is signed by `3 Leaps Infosec Team <infosec@3leaps.net>` with the
pinned signing subkey (`config/release/tagger-identity.txt`,
`config/release/signing-subkey.txt`, `docs/security/release-signing-keys.asc`,
`docs/security/canondocs-minisign.pub`, and `keys/expected-fingerprints.{txt,ndjson}`).
Set in the shell, never in the repo: `CANONDOCS_RELEASE_TAG`,
`CANONDOCS_DECERNOR_BIN` (absolute path to `decernor >= 0.1.8`),
`CANONDOCS_TAG_MESSAGE_DIR` (outside the repository), `CANONDOCS_TAGGER_NAME`,
`CANONDOCS_TAGGER_EMAIL`, `CANONDOCS_GPG_SIGNING_FINGERPRINT` (primary),
`CANONDOCS_PGP_KEY_ID` (`<subkey>!` matching `config/release/signing-subkey.txt`),
`CANONDOCS_GPG_HOMEDIR` (isolated `0700` directory outside the repository, never
`~/.gnupg`), `CANONDOCS_RELEASE_ANCHOR_FILE` (absolute path outside the
repository, never a symlink), and `LIMENSAFE_CATALOG_PATH` (required by
`make release-preflight` for `make surface-scan-release`).

The tag comes only from `CANONDOCS_RELEASE_TAG`. Every `release-*` target refuses
to start while the generic `RELEASE_TAG` is set, even to an empty value, so
`unset RELEASE_TAG` first. Each target that downloads, drafts, signs, uploads or
publishes also requires the tag to match `VERSION`; after a version bump on
`main`, run the remaining steps from a checkout of the tagged commit.

- [ ] Remote tag-protection ruleset and immutable releases: `make release-github-preflight`
- [ ] Pre-tag gate on the merged main commit (committed anchor verification, `make surface-scan-release`, workflow SHA-256 pin check, `make release-github-preflight`, content check, dates check, outside-`$HOME` clean-clone test, and `make pr-final`): `make release-preflight`
- [ ] Prepare and review the external tag message: `make release-prepare-tag-message`
- [ ] Create and verify the local signed tag: `make release-tag`
- [ ] Publish and verify the tag (ruleset, remote object, GitHub `valid`): `make release-push-tag`
- [ ] Verify the post-tag ceremony selector environment: `make release-post-tag-selector`
- [ ] Verify the published remote tag and record the external ceremony anchor (`CANONDOCS_RELEASE_ANCHOR_FILE`): `make release-record-anchor`

### Release Artifacts & Signing

The tag workflow is read-only. It verifies the signed tag, builds, and uploads
`release-artifacts-v<version>` as a workflow artifact. It does not create the
GitHub Release. A green tag workflow is not release authorization.

- [ ] Download the CI artifacts for the verified tag and cross-check the recorded
      ceremony anchor. Name the exact Release workflow run and its successful,
      latest attempt (`gh run list --workflow release.yml`); staging binds to
      that run's single `release-artifacts-v<version>` artifact by id and digest
      and refuses if a re-run appears during the download:

  ```bash
  export CANONDOCS_RELEASE_TAG=v<version>
  export CANONDOCS_RELEASE_ANCHOR_FILE=<abs-path-outside-repo>
  export RELEASE_RUN_ID=<run id> RELEASE_RUN_ATTEMPT=<attempt>
  make release-clean
  make release-download
  make release-verify-checksums
  ```

- [ ] Create the draft release from the verified local artifacts (body is
      `docs/releases/v<version>.md` from the tagged commit): `make release-create-draft`
- [ ] Sign the manifests (minisign and PGP both required; also set
      `CANONDOCS_MINISIGN_KEY`): `make release-sign`
- [ ] Stage and check public keys and Decernor fingerprint anchors from the verified tagged commit: `make release-export-keys release-verify-keys`
- [ ] Verify signatures (minisign and exact signing-subkey OpenPGP on `SHA256SUMS` and `SHA512SUMS`): `make release-verify-signatures`
- [ ] Stage notes: `make release-notes`
- [ ] Upload provenance assets (manifests, signatures, both public keys, both anchor files, release notes) to the draft: `make release-upload`
- [ ] Preserve the package-manager URL and SHA256 block printed by `make release-upload`
- [ ] Promote the draft after byte-verifying it against the local signed set, then assert `.draft == false` and `.immutable == true`: `make release-publish`
- [ ] Clean-room download and full verification of the published release into `dist/published`: `make release-stage-published`

### Distribution

Official releases publish unwrapped, standalone executables
(`canondocs-darwin-arm64`, `canondocs-linux-amd64`, `canondocs-linux-arm64`,
`canondocs-windows-amd64.exe`, `canondocs-windows-arm64.exe`) listed in the
signed `SHA256SUMS` and `SHA512SUMS`. `3leaps/homebrew-tap`
(`Formula/canondocs.rb`) and `3leaps/scoop-bucket` (`bucket/canondocs.json`)
install those exact assets byte-for-byte: no source rebuilds, no bottles, no
wrapper scripts, no archives. Changing that is a consumer-visible packaging
change and is announced in the release notes.

- [ ] Verify `go install github.com/3leaps/canondocs/cmd/canondocs@v<version>` works
- [ ] Update `Formula/canondocs.rb` from the uploaded asset URLs and SHA256 values:
  - [ ] raw `canondocs-darwin-arm64`, `canondocs-linux-amd64`, `canondocs-linux-arm64` URLs
  - [ ] no Intel macOS entry
  - [ ] `license any_of: ["MIT", "Apache-2.0"]`
- [ ] Verify Homebrew: `brew install 3leaps/tap/canondocs && canondocs version`
- [ ] Update `bucket/canondocs.json` from the uploaded asset URLs and SHA256 values:
  - [ ] raw `canondocs-windows-amd64.exe` and `canondocs-windows-arm64.exe` URLs, 2-element `bin` rename pairs, no `extract_dir`
  - [ ] `"license": "MIT OR Apache-2.0"`
- [ ] Verify Scoop: `scoop install 3leaps/canondocs && canondocs version`
- [ ] Verify Go module proxy, Homebrew tap and Scoop bucket against `dist/published` and the tagged commit: `make release-verify-registries`

## Post-Release

- [ ] Monitor GitHub issues for release-related bugs

## Notes

- Some items may not apply to every release; never skip tests or review.
- When in doubt, consult @3leapsdave before proceeding.
