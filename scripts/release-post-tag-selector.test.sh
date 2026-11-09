#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd -P)"
# Synthetic fixture root: the committed pins are not read.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
root="$scratch/repo"
mkdir -p "$root/scripts" "$root/keys" "$root/config/release"
cp "$src/scripts/release-post-tag-selector.sh" "$root/scripts/"
version=1.2.3
tag="v$version"
primary="$(printf 'A%.0s' {1..40})"
subkey="$(printf 'B%.0s' {1..40})"
printf '%s\n' "$version" > "$root/VERSION"
printf 'gpg %s\nminisign %s\n' "$primary" "$(printf 'c%.0s' {1..64})" > "$root/keys/expected-fingerprints.txt"
printf '%s\n' "$subkey" > "$root/config/release/signing-subkey.txt"

CANONDOCS_RELEASE_TAG="$tag" \
    CANONDOCS_GPG_SIGNING_FINGERPRINT="$primary" \
    CANONDOCS_PGP_KEY_ID="${subkey}!" \
    "$root/scripts/release-post-tag-selector.sh" > /dev/null

# Missing bang (!) on subkey selector refuses
if CANONDOCS_RELEASE_TAG="$tag" \
    CANONDOCS_GPG_SIGNING_FINGERPRINT="$primary" \
    CANONDOCS_PGP_KEY_ID="$subkey" \
    "$root/scripts/release-post-tag-selector.sh" 2> /dev/null; then
    echo "error: accepted subkey selector without trailing !" >&2
    exit 1
fi

# Primary key passed as CANONDOCS_PGP_KEY_ID refuses
if CANONDOCS_RELEASE_TAG="$tag" \
    CANONDOCS_GPG_SIGNING_FINGERPRINT="$primary" \
    CANONDOCS_PGP_KEY_ID="${primary}!" \
    "$root/scripts/release-post-tag-selector.sh" 2> /dev/null; then
    echo "error: accepted primary key instead of signing subkey" >&2
    exit 1
fi

# Wrong primary fingerprint refuses
if CANONDOCS_RELEASE_TAG="$tag" \
    CANONDOCS_GPG_SIGNING_FINGERPRINT="$(printf '%040d' 0)" \
    CANONDOCS_PGP_KEY_ID="${subkey}!" \
    "$root/scripts/release-post-tag-selector.sh" 2> /dev/null; then
    echo "error: accepted wrong primary fingerprint" >&2
    exit 1
fi

# Version mismatch refuses
if CANONDOCS_RELEASE_TAG="v99.99.99" \
    CANONDOCS_GPG_SIGNING_FINGERPRINT="$primary" \
    CANONDOCS_PGP_KEY_ID="${subkey}!" \
    "$root/scripts/release-post-tag-selector.sh" 2> /dev/null; then
    echo "error: accepted mismatched tag version" >&2
    exit 1
fi

# A malformed committed subkey pin refuses.
printf 'PLACEHOLDER\n' > "$root/config/release/signing-subkey.txt"
if CANONDOCS_RELEASE_TAG="$tag" \
    CANONDOCS_GPG_SIGNING_FINGERPRINT="$primary" \
    CANONDOCS_PGP_KEY_ID="${subkey}!" \
    "$root/scripts/release-post-tag-selector.sh" 2> /dev/null; then
    echo "error: accepted a malformed signing-subkey pin" >&2
    exit 1
fi

echo "[ok] post-tag selector controls passed"
