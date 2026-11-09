# shellcheck shell=bash
# Synthetic release pins for tooling tests. The committed pins are never read
# by the suites; every suite that needs a pin set mints a throwaway one.
#
# make_throwaway_pins <dest-root> <work-dir>
#   Writes public material only under <dest-root>:
#     docs/security/release-signing-keys.asc  (ed25519 cert primary + sign subkey)
#     docs/security/canondocs-minisign.pub
#     keys/expected-fingerprints.txt / .ndjson (Decernor fingerprint records)
#     config/release/signing-subkey.txt
#   Private material stays under <work-dir> (pins-gpg/, pins-minisign.key).
#   Requires gpg, minisign, python3 and an absolute CANONDOCS_DECERNOR_BIN.
#   Sets THROWAWAY_GNUPGHOME, THROWAWAY_PRIMARY, THROWAWAY_SUBKEY and
#   THROWAWAY_MINISIGN_KEY. Callers kill the agent:
#     gpgconf --homedir "$THROWAWAY_GNUPGHOME" --kill all
make_throwaway_pins() {
    local dest="$1" work="$2" bin="${CANONDOCS_DECERNOR_BIN:?CANONDOCS_DECERNOR_BIN required}"
    THROWAWAY_GNUPGHOME="$work/pins-gpg"
    THROWAWAY_MINISIGN_KEY="$work/pins-minisign.key"
    mkdir -p "$dest/docs/security" "$dest/keys" "$dest/config/release"
    mkdir -m 700 "$THROWAWAY_GNUPGHOME"
    gpg --homedir "$THROWAWAY_GNUPGHOME" --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-generate-key 'Synthetic signing <signing@example.invalid>' ed25519 cert 1d > /dev/null 2>&1
    THROWAWAY_PRIMARY="$(gpg --homedir "$THROWAWAY_GNUPGHOME" --batch --with-colons --fingerprint --list-keys |
        awk -F: '$1=="fpr" {print $10;exit}')"
    gpg --homedir "$THROWAWAY_GNUPGHOME" --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-add-key "$THROWAWAY_PRIMARY" ed25519 sign 1d > /dev/null 2>&1
    THROWAWAY_SUBKEY="$(gpg --homedir "$THROWAWAY_GNUPGHOME" --batch --with-colons --with-subkey-fingerprint --list-keys |
        awk -F: '$1=="sub" {s=1;next} s && $1=="fpr" {print $10;exit}')"
    gpg --homedir "$THROWAWAY_GNUPGHOME" --batch --armor --export "$THROWAWAY_PRIMARY" \
        > "$dest/docs/security/release-signing-keys.asc"
    minisign -G -W -p "$dest/docs/security/canondocs-minisign.pub" -s "$THROWAWAY_MINISIGN_KEY" > /dev/null
    "$bin" fingerprint "$dest/docs/security/release-signing-keys.asc" --class public --kind gpg \
        --format ndjson --path-mode none --gpg-role primary > "$work/pins-gpg.ndjson"
    "$bin" fingerprint "$dest/docs/security/canondocs-minisign.pub" --class public --kind minisign \
        --format ndjson --path-mode none > "$work/pins-minisign.ndjson"
    python3 -I - "$work" "$dest/keys" << 'PY'
import json, pathlib, sys
base, keys = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
g = [json.loads(line) for line in (base / 'pins-gpg.ndjson').read_text().splitlines() if line]
m = [r for r in (json.loads(line) for line in (base / 'pins-minisign.ndjson').read_text().splitlines() if line)
     if r.get('fingerprint_scheme') == 'minisign-public-blob-sha256-v1']
if len(g) != 1 or len(m) != 1:
    raise SystemExit('error: throwaway pins: unexpected fingerprint records')
(keys / 'expected-fingerprints.ndjson').write_text(''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in (g[0], m[0])))
(keys / 'expected-fingerprints.txt').write_text('gpg ' + g[0]['fingerprint'] + '\nminisign ' + m[0]['fingerprint'] + '\n')
PY
    printf '%s\n' "$THROWAWAY_SUBKEY" > "$dest/config/release/signing-subkey.txt"
}
