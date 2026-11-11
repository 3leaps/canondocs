# Release verification

Official releases use a GPG-signed annotated Git tag and minisign-signed
SHA256SUMS and SHA512SUMS manifests. These are separate signatures.

Establish the expected GPG primary and exact signing subkey, and the minisign
public-blob fingerprint, through an independently trusted maintainer channel
before accepting downloaded public keys. A key distributed beside a signature
is not independent authentication.

The public pins are [`release-signing-keys.asc`](release-signing-keys.asc),
[`canondocs-minisign.pub`](canondocs-minisign.pub), and the exact signing subkey
[`config/release/signing-subkey.txt`](../../config/release/signing-subkey.txt).
The tagger identity is
[`config/release/tagger-identity.txt`](../../config/release/tagger-identity.txt).
Tag verification and release staging extract these from the verified tagged
commit as inert blobs, not from the current checkout or an external public-key
locator. The published `canondocs-minisign.pub`,
`canondocs-release-signing-key.asc`, `expected-fingerprints.txt`, and
`expected-fingerprints.ndjson` assets must match the committed files
byte-for-byte (`make release-stage-published`); independent fingerprint
verification remains required. Post-publication registry parity across the Go
module proxy, `3leaps/homebrew-tap`, and `3leaps/scoop-bucket` is verified by
`make release-verify-registries`.

The text and NDJSON anchors in [`keys/`](../../keys/) use Decernor's
`openpgp-fingerprint-v1` primary and `minisign-public-blob-sha256-v1` schemes.
The minisign fingerprint covers the decoded public blob, not its comment or
whole file. Verify exported public material against both anchors with Decernor
0.1.8 or newer:

```bash
decernor fingerprint verify \
  --anchors keys/expected-fingerprints.txt \
  --anchors-ndjson keys/expected-fingerprints.ndjson \
  --gpg docs/security/release-signing-keys.asc \
  --minisign docs/security/canondocs-minisign.pub
```

Then use the approved minisign public key to verify both manifests and check
every listed digest. Require the complete expected asset set; do not use
`--ignore-missing` for a full release verification.

Tag verification (`scripts/verify-pinned-tag.sh`) uses an isolated keyring and
requires the exact signing subkey and the committed tagger identity. GitHub
Verified with reason `valid` is an additional check. Tags created before the
pin was committed are not verified by it and are not re-signed.

The tag workflow has read-only permissions. It verifies the tag, builds the
release artifacts, and uploads them as a workflow artifact. It does not sign,
create a GitHub Release, or publish packages. A green tag workflow is a
consistency signal, not release authorization. Maintainers verify the remote
tag, object and commit from trusted checkout code before signing or
publication. Tag protection and the maintainer ceremony remain part of the
publication boundary.

## Raw-asset packaging invariant and digest-pinned verification

1. **Raw-executable release contract:** Official `canondocs` GitHub Releases
   publish unwrapped, standalone platform executables (`canondocs-darwin-arm64`,
   `canondocs-linux-amd64`, `canondocs-linux-arm64`,
   `canondocs-windows-amd64.exe`, `canondocs-windows-arm64.exe`) listed directly
   in signed `SHA256SUMS` and `SHA512SUMS`.
2. **Byte-for-byte package-manager equivalence:** `3leaps/homebrew-tap`
   (`Formula/canondocs.rb`, and any versioned `Formula/canondocs@0.<minor>.rb`)
   and `3leaps/scoop-bucket` (`bucket/canondocs.json`, and any versioned
   `bucket/canondocs-0.<minor>.json`) install those exact release assets
   byte-for-byte — no source rebuilds, no Homebrew bottles (`bottle do` /
   Mach-O header rewriting / re-signing), no wrapper scripts
   (`write_env_script`), and no archive repackaging.
3. **Consumer-visible change gate:** Replacing raw executable assets with
   `.tar.gz` / `.zip` archives (or introducing bottles/wrappers that alter
   installed binary bytes) is a consumer-visible packaging change that requires
   prior design review and explicit announcement in release notes
   (`CHANGELOG.md`, `RELEASE_NOTES.md`, `docs/releases/v<version>.md`).

### Pinned & digest-verified automation installs

- `3leaps/tap/canondocs` and `3leaps/scoop-bucket` (`canondocs`) track **latest
  stable only**. Automation runners that gate execution by verifying the binary
  SHA-256 against a release's signed `SHA256SUMS` should download the exact
  tagged raw release asset into a runner-private directory (for example via
  `sfetch --repo 3leaps/canondocs --tag v0.1.0 --dest-dir <runner-bin>` or
  verified GitHub Release download) rather than relying on mutable workstation
  `PATH`, or hold workstation upgrades explicitly with `brew pin canondocs` /
  `scoop hold canondocs`.
- **Homebrew vs Windows Scoop `PATH` resolution:**
  - On **Homebrew** (macOS/Linux), `$(brew --prefix)/bin/canondocs` is a symlink
    to the raw release executable in the Cellar, so hashing the resolved `PATH`
    entry matches `SHA256SUMS` directly.
  - On **Windows Scoop**, `bucket/canondocs.json` maps
    `"bin": [["canondocs-windows-<arch>.exe", "canondocs"]]`, so Scoop places its
    generic `shim.exe` launcher at `~\scoop\shims\canondocs.exe` on `PATH` while
    keeping the untouched raw release executable at
    `~\scoop\apps\canondocs\current\canondocs-windows-<arch>.exe` (discoverable
    via `scoop which canondocs` or the adjacent `canondocs.shim` file). Any
    verifier checking `SHA256SUMS` on Windows must hash the target of
    `scoop which canondocs` (or point its executable path directly at
    `canondocs-windows-<arch>.exe`), not `shims\canondocs.exe`.
