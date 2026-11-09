#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
export PYTHONDONTWRITEBYTECODE=1

if [[ $# -gt 0 ]]; then
    python3 -B -E "$root/scripts/release-workflow-permissions.py" check "$1"
    exit 0
fi

python3 -B -E "$root/scripts/release-workflow-permissions.py" check
python3 -B -E "$root/scripts/release-workflow-permissions.py" mutations
python3 -B -E "$root/scripts/release-workflow-pin.py" check

# Without PyYAML the checker falls back to a line scan plus yq. Shell text in
# run: block scalars (for example "${VAR:?}") is not YAML structure, while a
# flow mapping in the YAML itself is still refused.
fallback() {
    python3 -B -E -c 'import runpy, sys
sys.modules["yaml"] = None
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")' "$root/scripts/release-workflow-permissions.py" "$@"
}
fallback check > /dev/null
fb="$(mktemp -d)"
sed 's/^permissions:$/permissions: {contents: read}\nx-permissions:/' "$root/.github/workflows/release.yml" > "$fb/release.yml"
if fallback check "$fb/release.yml" > /dev/null 2> "$fb/err"; then
    rm -rf "$fb"
    echo 'error: fallback checker accepted a flow-style mapping' >&2
    exit 1
fi
grep -q 'flow-style YAML mappings are forbidden' "$fb/err" || {
    cat "$fb/err" >&2
    rm -rf "$fb"
    echo 'error: fallback checker refused for another reason' >&2
    exit 1
}
rm -rf "$fb"

# Verify release-workflow-pin.py verify-commit ignores hostile GIT_* env vars
# and git replace refs.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/.github/workflows" "$repo/config/release" "$repo/scripts"
cp "$root"/.github/workflows/*.yml "$repo/.github/workflows/"
cp "$root/config/release/release-workflow.sha256" "$repo/config/release/release-workflow.sha256"
cp "$root/scripts/release-workflow-pin.py" "$repo/scripts/"
git init -q -b main "$repo"
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" add .github/workflows config/release/release-workflow.sha256
git -C "$repo" commit -qm 'good workflows'
good_commit="$(git -C "$repo" rev-parse HEAD)"

printf '# tampered\n' >> "$repo/.github/workflows/release.yml"
git -C "$repo" commit -qam 'tampered workflow'
bad_commit="$(git -C "$repo" rev-parse HEAD)"
bad_blob="$(git -C "$repo" --no-replace-objects rev-parse "$bad_commit:.github/workflows/release.yml")"
good_blob="$(git -C "$repo" --no-replace-objects rev-parse "$good_commit:.github/workflows/release.yml")"
git -C "$repo" replace "$bad_blob" "$good_blob"

GIT_DIR="$scratch/nonexistent" GIT_WORK_TREE="$scratch/nonexistent" \
    python3 -B -E "$repo/scripts/release-workflow-pin.py" verify-commit "$good_commit" > /dev/null
if GIT_DIR="$scratch/nonexistent" GIT_REPLACE_REF_BASE="refs/replace/" \
    python3 -B -E "$repo/scripts/release-workflow-pin.py" verify-commit "$bad_commit" 2> /dev/null; then
    echo 'error: release-workflow-pin.py verify-commit followed a git replace ref' >&2
    exit 1
fi

echo '[ok] release workflow permissions, mutation controls, and SHA-256 pin verified'
