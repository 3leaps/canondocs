# vX.Y.Z Release Notes

This file is the GitHub release body. `make release-create-draft` uploads it
verbatim from the tagged commit, so write it for someone installing the
release. Relative links do not resolve on a release page: link repository
files with tag-scoped URLs, `https://github.com/3leaps/canondocs/blob/vX.Y.Z/<path>`.

## Summary

Short summary of the release for someone installing it.

## Highlights

- ...

## Release provenance

- Before importing a downloaded public key, establish the expected GPG signing
  key and minisign public-key fingerprint through an independently trusted
  maintainer channel. Follow the complete
  [release-verification guide](https://github.com/3leaps/canondocs/blob/vX.Y.Z/docs/security/README.md).
- Release tags are GPG-signed. After validating the public material against
  the committed anchors, verify with `git tag -v vX.Y.Z`.
- Checksum manifests are signed with minisign and PGP; the published assets are
  byte-identical to the signed set.

## Install

```bash
brew install 3leaps/tap/canondocs                      # macOS Apple Silicon, Linux
go install github.com/3leaps/canondocs/cmd/canondocs@vX.Y.Z
```

```powershell
scoop bucket add 3leaps https://github.com/3leaps/scoop-bucket
scoop install canondocs
```

## Verification

- ...

See [CHANGELOG.md](https://github.com/3leaps/canondocs/blob/vX.Y.Z/CHANGELOG.md) for the full list.
