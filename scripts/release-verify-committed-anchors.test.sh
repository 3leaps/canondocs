#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# In-tree anchor verification: no maintainer env vars; mismatch fails.
# Runs against a fixture root with throwaway pins; the committed tree is
# never read or modified.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=scripts/testdata/throwaway-pins.sh
source "$src/scripts/testdata/throwaway-pins.sh"
bin="${CANONDOCS_DECERNOR_BIN:-$(command -v decernor || true)}"
[[ -n "$bin" && -x "$bin" && "$bin" == /* && ! -L "$bin" ]] || {
    echo 'error: CANONDOCS_DECERNOR_BIN required (CI installs Decernor from config/release/decernor-ci-sha256.txt)' >&2
    exit 1
}
export CANONDOCS_DECERNOR_BIN="$bin"
scratch="$(mktemp -d)"
cleanup() {
    gpgconf --homedir "$scratch/pins-gpg" --kill all > /dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT
root="$scratch/repo"
mkdir -p "$root/scripts"
cp "$src/scripts/release-verify-committed-anchors.sh" "$src/scripts/release-decernor.sh" "$root/scripts/"
make_throwaway_pins "$root" "$scratch"
run() {
    env -u CANONDOCS_PGP_KEY_ID -u CANONDOCS_GPG_SIGNING_FINGERPRINT -u CANONDOCS_MINISIGN_PUB \
        "$root/scripts/release-verify-committed-anchors.sh"
}
# Must not require the maintainer-only pin variables.
run > /dev/null
anchors="$root/keys/expected-fingerprints.txt"
cp "$anchors" "$scratch/good.txt"
# A mutated minisign anchor must fail closed.
python3 -I - "$scratch/good.txt" "$anchors" << 'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
lines[1] = 'minisign ' + ('0' * 64)
Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
PY
if run > /dev/null 2>&1; then
    echo 'error: mismatched minisign anchor was accepted' >&2
    exit 1
fi
# A mutated gpg anchor must fail closed.
python3 -I - "$scratch/good.txt" "$anchors" << 'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
lines[0] = 'gpg ' + ('0' * 40)
Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
PY
if run > /dev/null 2>&1; then
    echo 'error: mismatched gpg anchor was accepted' >&2
    exit 1
fi
# A placeholder pin must fail closed.
cp "$scratch/good.txt" "$anchors"
printf 'PLACEHOLDER\n' > "$root/docs/security/canondocs-minisign.pub"
if run > /dev/null 2>&1; then
    echo 'error: placeholder minisign pin was accepted' >&2
    exit 1
fi
echo '[ok] committed-anchor verification uses only in-tree material'
