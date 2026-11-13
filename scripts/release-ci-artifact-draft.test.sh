#!/usr/bin/env bash
# Stub-gh controls for release-fetch-ci-artifacts.sh and release-create-draft.sh.
# No live GitHub call is made; the stub records every invocation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=scripts/testdata/sha-helpers.sh
source "$root/scripts/testdata/sha-helpers.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name 'Fixture'
git -C "$repo" config user.email fixture@example.invalid
printf 'x\n' > "$repo/file"
git -C "$repo" add file
mkdir -p "$repo/docs/releases" "$repo/.github/workflows" "$repo/config/release" "$repo/scripts"
printf '# fixture v1.2.3\n\nCurated notes.\n' > "$repo/docs/releases/v1.2.3.md"
cp "$root"/.github/workflows/*.yml "$repo/.github/workflows/"
cp "$root/config/release/release-workflow.sha256" "$repo/config/release/release-workflow.sha256"
git -C "$repo" add docs/releases/v1.2.3.md .github/workflows config/release/release-workflow.sha256
git -C "$repo" commit -qm fixture
git -C "$repo" tag -am 'Fixture release' v1.2.3
commit="$(git -C "$repo" rev-parse HEAD)"
cp "$root/scripts/release-fetch-ci-artifacts.sh" "$root/scripts/release-create-draft.sh" \
    "$root/scripts/release-gh.sh" "$root/scripts/release-workflow-pin.py" "$repo/scripts/"
object="$(git -C "$repo" rev-parse refs/tags/v1.2.3)"
# Stand-in for the trusted published-tag gate (its own suite uses real
# signatures). It reports the fixture anchor, records any expected anchor it is
# asked to enforce, and fails when told the remote tag was replaced.
cat > "$repo/scripts/release-verify-published-tag.sh" << SH
#!/usr/bin/env bash
printf 'reverify %s expect=%s/%s\\n' "\$CANONDOCS_RELEASE_TAG" "\${CANONDOCS_EXPECTED_TAG_OBJECT:-}" "\${CANONDOCS_EXPECTED_COMMIT:-}" >> "\$FIXTURE_LOG"
[[ "\$CANONDOCS_RELEASE_TAG" == v1.2.3 ]] || { echo 'error: tag absent' >&2; exit 1; }
[[ "\${FIXTURE_TAG_REPLACED:-0}" == 0 ]] || { echo 'error: tag replaced' >&2; exit 1; }
# FIXTURE_PLANT_LINK: plant symlinks to the ceremony anchor beside the
# script's private anchor file, where a predictable sidecar name would be.
if [[ "\${FIXTURE_PLANT_LINK:-0}" == 1 ]]; then
    for suffix in .expected .tmp .new .cmp; do
        ln -s "\$CANONDOCS_RELEASE_ANCHOR_FILE" "\$CANONDOCS_ANCHOR_OUT\$suffix"
        printf '%s\\n' "\$CANONDOCS_ANCHOR_OUT\$suffix" >> "\$FIXTURE_DIR/planted"
    done
fi
if [[ -n "\${CANONDOCS_ANCHOR_OUT:-}" ]]; then
    printf 'tag=v1.2.3\\nobject=%s\\ncommit=%s\\n' "$object" "$commit" > "\$CANONDOCS_ANCHOR_OUT"
fi
SH
chmod +x "$repo/scripts/release-verify-published-tag.sh"

# Stub gh. FIXTURE_ATTEMPT is the run-attempt JSON the API returns and
# FIXTURE_LATEST is the latest attempt number of that run;
# FIXTURE_RELEASE_EXISTS controls `gh release view`. Every call is logged.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/gh" << 'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_LOG"
case "$1 $2" in
"api "*)
    path="$2"
    jq_filter=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == --jq ]] && jq_filter="$2"
        shift
    done
    case "$path" in
    */actions/workflows/release.yml/runs\?*)
        # FIXTURE_RUNS is the workflow_runs page (the stub applies no server-side
        # filter); FIXTURE_RUNS_TOTAL overrides total_count. A status filter in
        # the query gets an empty page, as GitHub can return for a run that has
        # just completed.
        if [[ "$path" == *status=* ]]; then
            body='{"total_count":0,"workflow_runs":[]}'
        elif [[ -n "${FIXTURE_RUNS_RAW:-}" ]]; then
            body="$FIXTURE_RUNS_RAW"
        else
            body="$(jq -c --arg total "${FIXTURE_RUNS_TOTAL:-}" \
                '{total_count: (if $total == "" then length else ($total | tonumber) end), workflow_runs: .}' <<< "${FIXTURE_RUNS:-[]}")"
        fi
        ;;
    */attempts/*) body="${FIXTURE_ATTEMPT:-}" ;;
    */runs/*/artifacts\?per_page=100)
        # Listing calls are counted so a test can change the answer between the
        # before- and after-download snapshots (a re-run landing mid-download).
        n="$(($(cat "$FIXTURE_DIR/listings" 2> /dev/null || echo 0) + 1))"
        printf '%s\n' "$n" > "$FIXTURE_DIR/listings"
        id="${FIXTURE_ARTIFACT_ID:-501}"
        [[ "$n" -ge 2 && -n "${FIXTURE_ARTIFACT_ID_AFTER:-}" ]] && id="$FIXTURE_ARTIFACT_ID_AFTER"
        digest="${FIXTURE_DIGEST:-sha256:$(shasum -a 256 "$FIXTURE_DIR/artifact.zip" 2> /dev/null | awk '{print $1}')}"
        body="$(jq -n --argjson id "$id" --arg d "$digest" --arg c "${FIXTURE_ARTIFACT_SHA:-$FIXTURE_COMMIT}" \
            --argjson total "$([[ "$n" -ge 2 && -n "${FIXTURE_TOTAL_COUNT_AFTER:-}" ]] && echo "$FIXTURE_TOTAL_COUNT_AFTER" || echo "${FIXTURE_TOTAL_COUNT:-1}")" \
            '{total_count: $total, artifacts: [{id: $id, name: "release-artifacts-v1.2.3", expired: false, digest: $d,
              workflow_run: {id: 11, head_sha: $c}}]}')"
        ;;
    */artifacts/*/zip)
        [[ "$path" == */artifacts/"${FIXTURE_ARTIFACT_ID:-501}"/zip ]] || exit 1
        cat "$FIXTURE_DIR/artifact.zip"
        exit 0
        ;;
    *)
        m="$(($(cat "$FIXTURE_DIR/runs" 2> /dev/null || echo 0) + 1))"
        printf '%s\n' "$m" > "$FIXTURE_DIR/runs"
        latest="${FIXTURE_LATEST:-1}"
        [[ "$m" -ge 2 && -n "${FIXTURE_LATEST_AFTER:-}" ]] && latest="$FIXTURE_LATEST_AFTER"
        body="{\"run_attempt\":$latest}"
        ;;
    esac
    [[ -n "$body" ]] || exit 1
    if [[ -n "$jq_filter" ]]; then jq -c "$jq_filter" <<< "$body"; else printf '%s\n' "$body"; fi
    ;;
"run download")
    dir=""
    name=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == --dir ]] && dir="$2"
        [[ "$1" == --name ]] && name="$2"
        shift
    done
    [[ "$name" == "release-artifacts-v1.2.3" ]] || exit 1
    printf 'pkg\n' > "$dir/canondocs-linux-amd64"
    ;;
"release view") [[ "${FIXTURE_RELEASE_EXISTS:-0}" == 1 ]] ;;
"release create") exit 0 ;;
*) exit 1 ;;
esac
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" FIXTURE_LOG="$scratch/gh.log" FIXTURE_DIR="$scratch/fx" FIXTURE_COMMIT="$commit"
mkdir -p "$FIXTURE_DIR"
# The CI artifact: a zip holding one release binary.
python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("canondocs-linux-amd64","pkg\n"); z.close()' "$FIXTURE_DIR/artifact.zip"
reset_listings() { rm -f "$FIXTURE_DIR/listings" "$FIXTURE_DIR/runs"; }

fail() {
    local reason="$1"
    shift
    if (cd "$repo" && "$@") > "$scratch/out" 2>&1; then
        echo "error: expected rejection: $reason" >&2
        exit 1
    fi
    grep -q "$reason" "$scratch/out" || {
        echo "error: missing named rejection: $reason" >&2
        cat "$scratch/out" >&2
        exit 1
    }
}
attempt_json() { # conclusion event head_sha attempt [path] [branch]
    printf '{"path":"%s","event":"%s","head_branch":"%s","head_sha":"%s","status":"completed","conclusion":"%s","run_attempt":%s}' \
        "${5:-.github/workflows/release.yml}" "$2" "${6:-v1.2.3}" "$3" "$1" "$4"
}
good="$(attempt_json success push "$commit" 2)"
export CANONDOCS_RELEASE_RUN_ID=11 CANONDOCS_RELEASE_RUN_ATTEMPT=2 FIXTURE_LATEST=2
# The ceremony anchor recorded when the tag was published, outside the
# repository on a path with no symlink (mktemp -d may sit under one: resolve).
anchors="$(cd "$scratch" && pwd -P)/anchors"
mkdir -p "$anchors"
printf 'tag=v1.2.3\nobject=%s\ncommit=%s\n' "$object" "$commit" > "$anchors/ceremony.anchor"
export CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/ceremony.anchor"

# Fetch: refuses a non-canonical tag, a missing local tag, a missing run id or
# attempt, and any named attempt that is not a successful push-triggered
# release run for this tag on the tagged commit or is not the latest attempt.
fail 'usage' ./scripts/release-fetch-ci-artifacts.sh 1.2.3 "$scratch/d0"
fail 'published tag v9.9.9 failed verification' ./scripts/release-fetch-ci-artifacts.sh v9.9.9 "$scratch/d0"
# The ceremony anchor is required and must match the verified tag.
FIXTURE_ATTEMPT="$good" fail 'CANONDOCS_RELEASE_ANCHOR_FILE required' \
    env -u CANONDOCS_RELEASE_ANCHOR_FILE ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
CANONDOCS_RELEASE_ANCHOR_FILE='' FIXTURE_ATTEMPT="$good" fail 'CANONDOCS_RELEASE_ANCHOR_FILE required' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/absent.anchor" FIXTURE_ATTEMPT="$good" fail 'ceremony anchor file not found' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
mkdir -p "$anchors/dir.anchor"
CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/dir.anchor" FIXTURE_ATTEMPT="$good" fail 'ceremony anchor file not found' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
# Path rules match the writer: absolute, outside the repository, no symlink.
cp "$anchors/ceremony.anchor" "$repo/checkout.anchor"
CANONDOCS_RELEASE_ANCHOR_FILE=checkout.anchor FIXTURE_ATTEMPT="$good" fail 'must be an absolute path' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
CANONDOCS_RELEASE_ANCHOR_FILE="$(cd "$repo" && pwd -P)/checkout.anchor" FIXTURE_ATTEMPT="$good" fail 'must be outside the repository' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
rm -f "$repo/checkout.anchor"
ln -s "$anchors/ceremony.anchor" "$anchors/link.anchor"
CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/link.anchor" FIXTURE_ATTEMPT="$good" fail 'must not be a symlink' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
ln -s "$anchors" "$(cd "$scratch" && pwd -P)/linked-dir"
CANONDOCS_RELEASE_ANCHOR_FILE="$(cd "$scratch" && pwd -P)/linked-dir/ceremony.anchor" FIXTURE_ATTEMPT="$good" \
    fail 'parent traverses a symlink' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
# Content must be exactly the three recorded lines: a different object, a
# suffixed value, a duplicate or extra line, or a missing newline refuses.
i=0
for bad in \
    "$(printf 'tag=v1.2.3\nobject=%040d\ncommit=%s\n' 0 "$commit")" \
    "$(printf 'tag=v1.2.3=x\nobject=%s=x\ncommit=%s=x\n' "$object" "$commit")" \
    "$(printf 'tag=v1.2.3\nobject=%s\ncommit=%s\nobject=\n' "$object" "$commit")" \
    "$(printf 'tag=v1.2.3\nobject=%s\ncommit=%s\nrun=1\n' "$object" "$commit")"; do
    i=$((i + 1))
    printf '%s\n' "$bad" > "$anchors/bad-$i.anchor"
    CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/bad-$i.anchor" FIXTURE_ATTEMPT="$good" \
        fail 'differs from the recorded ceremony anchor' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
done
# Links planted beside the private anchor file never receive a write: a stale
# ceremony anchor stays byte-for-byte unchanged and is still refused.
printf 'tag=v1.2.3\nobject=%040d\ncommit=%s\n' 0 "$commit" > "$anchors/planted.anchor"
cp "$anchors/planted.anchor" "$scratch/planted.before"
rm -f "$FIXTURE_DIR/planted"
CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/planted.anchor" FIXTURE_PLANT_LINK=1 FIXTURE_ATTEMPT="$good" \
    fail 'differs from the recorded ceremony anchor' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
[[ "$(wc -l < "$FIXTURE_DIR/planted")" -eq 4 ]] || { echo 'error: links were not planted' >&2; exit 1; }
cmp -s "$scratch/planted.before" "$anchors/planted.anchor" ||
    { echo 'error: a planted link redirected a write onto the ceremony anchor' >&2; exit 1; }
while IFS= read -r link; do rm -f "$link"; done < "$FIXTURE_DIR/planted"
printf 'tag=v1.2.3\nobject=%s\ncommit=%s' "$object" "$commit" > "$anchors/no-newline.anchor"
CANONDOCS_RELEASE_ANCHOR_FILE="$anchors/no-newline.anchor" FIXTURE_ATTEMPT="$good" \
    fail 'differs from the recorded ceremony anchor' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
# Run rows as the workflow-runs API returns them:
# id head_sha conclusion event [head_branch] [path] [status]
run_row() {
    printf '{"id":%s,"head_sha":"%s","conclusion":"%s","event":"%s","head_branch":"%s","path":"%s","status":"%s"}' \
        "$1" "$2" "$3" "$4" "${5:-v1.2.3}" "${6:-.github/workflows/release.yml}" "${7:-completed}"
}
other="$(printf '%040d' 0)"
# An empty named run is refused even when exactly one run could be selected.
CANONDOCS_RELEASE_RUN_ID='' FIXTURE_RUNS="[$(run_row 11 "$commit" success push)]" FIXTURE_ATTEMPT="$good" \
    fail 'CANONDOCS_RELEASE_RUN_ID required' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
CANONDOCS_RELEASE_RUN_ATTEMPT='' FIXTURE_ATTEMPT="$good" fail 'CANONDOCS_RELEASE_RUN_ATTEMPT required' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
# Unprefixed selectors, even empty or alongside the prefixed ones, are refused
# so a run named for another repository can never select this release.
for unprefixed in RELEASE_RUN_ID=11 RELEASE_RUN_ATTEMPT=2 RELEASE_RUN_ID= RELEASE_RUN_ATTEMPT=; do
    FIXTURE_ATTEMPT="$good" fail 'unprefixed RELEASE_RUN_ID or RELEASE_RUN_ATTEMPT is set' \
        env "$unprefixed" ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
done
# Without a named run, exactly one successful push-triggered release.yml run
# for the tag at the tagged commit must be listed; each decoy differs in one
# condition the script checks.
for runs in \
    '[]' \
    "[$(run_row 11 "$commit" success push),$(run_row 12 "$commit" success push)]" \
    "[$(run_row 11 "$other" success push)]" \
    "[$(run_row 11 "$commit" failure push)]" \
    "[$(run_row 11 "$commit" success workflow_dispatch)]" \
    "[$(run_row 11 "$commit" success push main)]" \
    "[$(run_row 11 "$commit" success push v1.2.3 .github/workflows/ci.yml)]" \
    "[$(run_row 11 "$commit" success push v1.2.3 .github/workflows/release.yml in_progress)]"; do
    FIXTURE_RUNS="$runs" FIXTURE_ATTEMPT="$good" fail 'CANONDOCS_RELEASE_RUN_ID required' \
        env -u CANONDOCS_RELEASE_RUN_ID ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
done
# A workflow_runs that is not an array is refused, even holding one eligible run.
FIXTURE_RUNS_RAW="{\"total_count\":1,\"workflow_runs\":{\"only\":$(run_row 11 "$commit" success push)}}" FIXTURE_ATTEMPT="$good" \
    fail 'run listing for v1.2.3 is incomplete' \
    env -u CANONDOCS_RELEASE_RUN_ID ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
# A listing that does not hold every matching run (a second page) is refused,
# even when the first page holds exactly one eligible run.
FIXTURE_RUNS="[$(run_row 11 "$commit" success push)]" FIXTURE_RUNS_TOTAL=101 FIXTURE_ATTEMPT="$good" \
    fail 'run listing for v1.2.3 is incomplete' \
    env -u CANONDOCS_RELEASE_RUN_ID ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
for bad in \
    "$(attempt_json failure push "$commit" 2)" \
    "$(attempt_json success workflow_dispatch "$commit" 2)" \
    "$(attempt_json success push "$(printf '%040d' 0)" 2)" \
    "$(attempt_json success push "$commit" 1)" \
    "$(attempt_json success push "$commit" 2 .github/workflows/ci.yml)" \
    "$(attempt_json success push "$commit" 2 .github/workflows/release.yml v1.2.4)" \
    "$(attempt_json success push "$commit" 2 | sed 's/"completed"/"in_progress"/')"; do
    FIXTURE_ATTEMPT="$bad" fail 'is not a successful release run' \
        ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
done
FIXTURE_ATTEMPT="$good" FIXTURE_LATEST=3 fail 'has a later attempt' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d1"
# Refuses a non-empty destination.
mkdir -p "$scratch/full"
printf 'stale\n' > "$scratch/full/stale"
FIXTURE_ATTEMPT="$good" fail 'is not empty' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/full"
# Downloads exactly the one artifact recorded from the named, verified attempt,
# checks its bytes against the recorded digest, and records both in the anchor.
digest="sha256:$(shasum -a 256 "$FIXTURE_DIR/artifact.zip" | awk '{print $1}')"
: > "$FIXTURE_LOG"
reset_listings
(cd "$repo" && FIXTURE_ATTEMPT="$good" ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/d2") > /dev/null
grep -q '^api repos/3leaps/canondocs/actions/artifacts/501/zip' "$FIXTURE_LOG"
if grep -q '^run download' "$FIXTURE_LOG"; then echo 'error: used gh run download' >&2; exit 1; fi
[[ "$(cat "$scratch/d2.anchor")" == "$(printf 'tag=v1.2.3\nobject=%s\ncommit=%s\nrun=11\nattempt=2\nartifact=501\ndigest=%s' "$object" "$commit" "$digest")" ]]
[[ -f "$scratch/d2/canondocs-linux-amd64" ]]
# Without named selectors, the single successful push-triggered run for the tag
# at the tagged commit is selected, at its latest attempt; decoys are skipped.
# The listing asks the server for exactly that filter, without a status filter.
reset_listings
: > "$FIXTURE_LOG"
(cd "$repo" && FIXTURE_ATTEMPT="$good" \
    FIXTURE_RUNS="[$(run_row 9 "$other" success push),$(run_row 10 "$commit" failure push),$(run_row 11 "$commit" success push)]" \
    env -u CANONDOCS_RELEASE_RUN_ID -u CANONDOCS_RELEASE_RUN_ATTEMPT \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/auto") > /dev/null
grep -qF "api repos/3leaps/canondocs/actions/workflows/release.yml/runs?branch=v1.2.3&event=push&head_sha=$commit&per_page=100 " "$FIXTURE_LOG" || {
    echo 'error: run listing did not request the exact server-side filter' >&2
    cat "$FIXTURE_LOG" >&2
    exit 1
}
[[ "$(cat "$scratch/auto.anchor")" == "$(printf 'tag=v1.2.3\nobject=%s\ncommit=%s\nrun=11\nattempt=2\nartifact=501\ndigest=%s' "$object" "$commit" "$digest")" ]]
# A re-run landing during the download changes the artifact: refuse, and leave
# no anchor behind.
reset_listings
FIXTURE_ATTEMPT="$good" FIXTURE_ARTIFACT_ID_AFTER=777 fail 'changed during download' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/race"
[[ ! -e "$scratch/race.anchor" ]]
# A later attempt appearing during the download is caught by the after-snapshot.
reset_listings
FIXTURE_ATTEMPT="$good" FIXTURE_LATEST_AFTER=3 fail 'has a later attempt' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/rerun"
[[ ! -e "$scratch/rerun.anchor" ]]
# Downloaded bytes that do not match the recorded digest refuse.
reset_listings
FIXTURE_ATTEMPT="$good" FIXTURE_DIGEST="sha256:$(printf '%064d' 0)" fail 'do not match its recorded digest' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/badbytes"
[[ ! -e "$scratch/badbytes.anchor" ]]
# An artifact built from another commit refuses.
reset_listings
FIXTURE_ATTEMPT="$good" FIXTURE_ARTIFACT_SHA="$(printf '%040d' 0)" fail 'does not hold exactly one unexpired' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/othersha"
[[ ! -e "$scratch/othersha.anchor" ]]
# A listing whose total_count exceeds the returned page refuses: "exactly
# one" is only judged over a complete listing.
reset_listings
FIXTURE_ATTEMPT="$good" FIXTURE_TOTAL_COUNT=31 fail 'artifact listing for run 11 is incomplete' \
    ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/paged"
[[ ! -e "$scratch/paged.anchor" ]]
# A snapshot failure surfaces its own error, not a later id/digest check.
for when in first after; do
    reset_listings
    if [[ "$when" == first ]]; then
        FIXTURE_ATTEMPT="$good" FIXTURE_TOTAL_COUNT=2 fail 'is incomplete' \
            ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/snap-$when"
    else
        FIXTURE_ATTEMPT="$good" FIXTURE_TOTAL_COUNT_AFTER=2 fail 'is incomplete' \
            ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/snap-$when"
    fi
    if grep -q -e 'artifact id is malformed' -e 'changed during download' "$scratch/out"; then
        echo "error: $when snapshot failure was swallowed" >&2
        exit 1
    fi
    [[ ! -e "$scratch/snap-$when.anchor" ]]
done
# Zip layout controls: each refuses, leaves dest empty, and writes no anchor.
good_zip="$scratch/good.zip"
cp "$FIXTURE_DIR/artifact.zip" "$good_zip"
zip_case() { # reason python-zip-builder
    local reason="$1" builder="$2" out="$scratch/z$RANDOM"
    python3 -I -c "import stat,sys,zipfile
z=zipfile.ZipFile(sys.argv[1],'w')
$builder
z.close()" "$FIXTURE_DIR/artifact.zip"
    reset_listings
    FIXTURE_ATTEMPT="$good" fail "$reason" ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$out"
    [[ -z "$(find "$out" -mindepth 1 2> /dev/null)" ]] || {
        echo "error: partial files left in dest after: $reason" >&2
        ls -la "$out" >&2
        exit 1
    }
    [[ ! -e "$out.anchor" ]]
}
zip_case 'artifact is empty' 'pass'
zip_case 'duplicate entry in artifact' 'z.writestr("canondocs-linux-amd64","a\n"); z.writestr("canondocs-linux-amd64","b\n")'
# Case-fold collisions refuse in the validator on every filesystem, not via
# a case-insensitive volume: the message names both spellings.
zip_case "collides with another entry: 'sha256sums' vs 'SHA256SUMS'" 'z.writestr("SHA256SUMS","a\n"); z.writestr("sha256sums","b\n")'
zip_case "collides with another entry: 'Canondocs-Linux-Amd64' vs 'canondocs-linux-amd64'" 'z.writestr("canondocs-linux-amd64","a\n"); z.writestr("Canondocs-Linux-Amd64","b\n")'
zip_case 'unexpected entry in artifact' 'z.writestr("canondocs-linux-amd64","a\n"); z.writestr("../evil","b\n")'
zip_case 'unexpected entry in artifact' 'z.writestr("canondocs-linux-amd64","a\n"); z.writestr(".hidden","b\n")'
zip_case 'unexpected entry in artifact' 'z.writestr("canondocs-linux-amd64","a\n"); z.writestr("sub/file","b\n")'
zip_case 'not a regular file' 'i=zipfile.ZipInfo("canondocs-linux-amd64"); i.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(i,"/etc/passwd")'
# A move that fails after earlier entries moved leaves dest empty. Two stub
# shapes for the second entry: fail before writing, and write a partial copy
# then fail (a cross-filesystem mv copies before it unlinks, so running out of
# space mid-copy leaves a partial destination file).
python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("a-first","1\n"); z.writestr("b-second","2\n"); z.close()' "$FIXTURE_DIR/artifact.zip"
for shape in before-write after-partial-write; do
    if [[ "$shape" == before-write ]]; then
        cat > "$scratch/bin/mv" << 'SH'
#!/usr/bin/env bash
case "$1" in */b-second) exit 1 ;; esac
exec /bin/mv "$@"
SH
    else
        cat > "$scratch/bin/mv" << 'SH'
#!/usr/bin/env bash
case "$1" in */b-second)
    head -c 1 "$1" > "${@: -1}/${1##*/}"
    exit 1
    ;;
esac
exec /bin/mv "$@"
SH
    fi
    chmod +x "$scratch/bin/mv"
    reset_listings
    FIXTURE_ATTEMPT="$good" fail 'could not move b-second' ./scripts/release-fetch-ci-artifacts.sh v1.2.3 "$scratch/mvfail-$shape"
    [[ -z "$(find "$scratch/mvfail-$shape" -mindepth 1 2> /dev/null)" ]] || {
        echo "error: partial files left in dest after a failed move ($shape)" >&2
        ls -la "$scratch/mvfail-$shape" >&2
        exit 1
    }
    [[ ! -e "$scratch/mvfail-$shape.anchor" ]]
done
rm "$scratch/bin/mv"
cp "$good_zip" "$FIXTURE_DIR/artifact.zip"

# Draft. Packages are staged against the anchor that fetch recorded.
stage() {
    local dir="$1" name
    rm -rf "$dir"
    mkdir -p "$dir"
    for name in canondocs-linux-amd64 canondocs-linux-arm64 \
        canondocs-windows-amd64.exe canondocs-windows-arm64.exe canondocs-darwin-arm64; do
        printf '%s\n' "$name" > "$dir/$name"
    done
    (cd "$dir" && sha_sum 256 canondocs-* > SHA256SUMS &&
        sha_sum 512 canondocs-* > SHA512SUMS)
    printf 'tag=v1.2.3\nobject=%s\ncommit=%s\nrun=11\nattempt=2\n' "$object" "$commit" > "$dir.anchor"
}
no_create() {
    if grep -q '^release create' "$FIXTURE_LOG"; then
        echo "error: draft created despite: $1" >&2
        exit 1
    fi
}
d="$scratch/draft"
draft_fail() {
    local reason="$1"
    : > "$FIXTURE_LOG"
    fail "$reason" ./scripts/release-create-draft.sh v1.2.3 "$d"
    no_create "$reason"
}

stage "$d"
FIXTURE_RELEASE_EXISTS=1 draft_fail 'already exists'
# Unlisted binary for a platform outside the release matrix, alongside a valid set.
stage "$d"
printf 'old\n' > "$d/canondocs-darwin-amd64"
draft_fail 'unexpected file'
# Extra, unexpected file of any kind (tooling residue).
stage "$d"
printf 'tool\n' > "$d/goneat"
draft_fail 'unexpected file'
# Hidden extra files, including names starting with "..", refuse.
for hidden in .stale '..stale' '...x'; do
    stage "$d"
    printf 'x\n' > "$d/$hidden"
    draft_fail 'unexpected file'
done
# A subdirectory is not a regular file and refuses.
stage "$d"
mkdir "$d/extra-dir"
draft_fail 'unexpected file'

# Missing expected archive.
stage "$d"
rm "$d/canondocs-darwin-arm64"
draft_fail 'missing release file'
# Manifest that omits an archive, and one listing an extra name.
stage "$d"
grep -v darwin "$d/SHA256SUMS" > "$d/x" && mv "$d/x" "$d/SHA256SUMS"
draft_fail 'does not list exactly'
stage "$d"
printf '%0128d  canondocs-darwin-amd64\n' 0 >> "$d/SHA512SUMS"
draft_fail 'malformed or duplicate\|does not list exactly'
# Archive whose bytes no longer match the manifest.
stage "$d"
printf 'tampered\n' > "$d/canondocs-linux-amd64"
draft_fail 'digest mismatch'
# Tag replaced between the earlier checks and the API call.
stage "$d"
FIXTURE_TAG_REPLACED=1 draft_fail 'no longer matches the verified anchor'
# Direct invocation with an empty directory fails closed.
rm -rf "$d"
mkdir -p "$d"
draft_fail 'missing release file'

# Missing, mismatched-tag or malformed anchor refuses.
stage "$d"
rm "$d.anchor"
draft_fail 'missing'
stage "$d"
sed -i.bak 's/^tag=v1.2.3$/tag=v1.2.4/' "$d.anchor"
draft_fail 'different tag'
stage "$d"
printf 'tag=v1.2.3\nobject=zz\ncommit=zz\n' > "$d.anchor"
draft_fail 'malformed'

# The draft body must come from the committed per-version notes.
stage "$d"
mv "$repo/docs/releases/v1.2.3.md" "$scratch/notes.hold"
draft_fail 'missing release notes'
mv "$scratch/notes.hold" "$repo/docs/releases/v1.2.3.md"
stage "$d"
printf 'edited after tagging\n' >> "$repo/docs/releases/v1.2.3.md"
draft_fail 'differs from the tagged commit'
git -C "$repo" checkout -q -- docs/releases/v1.2.3.md

# Valid creation: exactly the five archives plus both manifests, re-verified
# immediately before the create call.
stage "$d"
: > "$FIXTURE_LOG"
(cd "$repo" && ./scripts/release-create-draft.sh v1.2.3 "$d") > /dev/null
create="$(grep '^release create' "$FIXTURE_LOG")"
[[ "$create" == *' --verify-tag --draft '* ]]
[[ "$create" == *"--notes-file $repo/docs/releases/v1.2.3.md"* || "$create" == *'--notes-file '*'/docs/releases/v1.2.3.md'* ]]
[[ "$create" != *'--generate-notes'* ]]
[[ "$(grep -o 'canondocs-\(linux\|darwin\|windows\)-\(amd64\|arm64\)\(\.exe\)\?' <<< "$create" | sort -u | wc -l | tr -d ' ')" == 5 ]]
[[ "$create" == *'SHA256SUMS'* && "$create" == *'SHA512SUMS'* ]]
[[ "$(grep -n '' "$FIXTURE_LOG" | grep -E 'reverify|release create' | cut -d: -f2 | head -1)" == reverify* ]]
# The pre-API re-verification is bound to exactly the staged anchor.
grep -q "^reverify v1.2.3 expect=$object/$commit\$" "$FIXTURE_LOG"
echo '[ok] CI-artifact fetch and local draft controls passed'
