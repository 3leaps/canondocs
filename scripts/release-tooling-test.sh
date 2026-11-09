#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# Suites set every variable they exercise. Drop ambient maintainer and
# ceremony variables so a configured release shell cannot steer a suite;
# only the Decernor binary path is passed through.
for _var in $(compgen -e); do
    case "$_var" in
        CANONDOCS_DECERNOR_BIN) ;;
        CANONDOCS_* | LIMENSAFE_* | RELEASE_TAG | RELEASE_RUN_* | GH_TOKEN | GITHUB_TOKEN | GNUPGHOME) unset "$_var" ;;
    esac
done
unset _var
cd "$root"
suites="$root/config/release/tooling-suites.txt"
[[ -f "$suites" && ! -L "$suites" ]] || {
    echo 'error: missing config/release/tooling-suites.txt' >&2
    exit 1
}
expected="$(LC_ALL=C sort "$suites")"
actual="$(find "$root/scripts" -maxdepth 1 -name '*.test.sh' -print | sed 's|.*/||; s|\.test\.sh$||' | LC_ALL=C sort)"
[[ "$expected" == "$actual" ]] || {
    echo 'error: scripts/*.test.sh does not match config/release/tooling-suites.txt' >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    exit 1
}
while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    "$root/scripts/$suite.test.sh"
done < "$suites"
echo "[ok] all $(wc -l < "$suites" | tr -d ' ') release tooling suites passed"
