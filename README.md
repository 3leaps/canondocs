# canondocs

`canondocs` writes RFC 8785 (JSON Canonicalization Scheme, JCS) canonical
bytes, `sha256:` digests and golden test vectors for JSON, YAML 1.2.2 (Core
Schema) and NDJSON input.

It is a single static binary with no runtime dependencies. It reads one
bounded input, writes one result, and exits. It keeps no state, opens no
network connections, and never executes anything found in its input. Its
only dependencies are two pure-Go libraries:

- [canonprims](https://github.com/3leaps/canonprims) (`canon` package) for
  RFC 8785 canonicalization, I-JSON (RFC 7493) domain checks, NDJSON prefixes
  and canonical sets;
- [yamlprims](https://github.com/3leaps/yamlprims) (`yaml` package) for YAML
  1.2.2 Core Schema loading.

## Install

Release binaries and package-manager installs are not published yet. To build
from source (Go 1.24 or later):

```sh
make build        # writes bin/canondocs
```

## Usage

```sh
# JSON -> JCS (stdin or file; no trailing newline)
canondocs jcs payload.json
cat payload.json | canondocs jcs

# Verify JSON is already canonical (exit 0) or not (exit 1)
canondocs jcs --check payload.json

# YAML -> JCS (.yaml/.yml suffix, or --from yaml on stdin)
canondocs jcs policy.yaml
cat policy.yaml | canondocs jcs --from yaml --digest
# sha256:...

# Golden vector record (canonical JSON, then a newline)
canondocs jcs --vector fixture.yaml
# {"byte_length":42,"canonical":"...","digest":"sha256:...","scheme":"jcs/rfc8785"}

# NDJSON prefix cut: the first N lines as one canonical array
canondocs jcs --ndjson-array --head 4 --digest journal.ndjson

# Canonical sets: sort array elements by canonical bytes, refuse duplicates
canondocs jcs --sort-set --from yaml holds.yaml
canondocs jcs --sort-set --check seals.json

canondocs info               # scheme description, canonical JSON
canondocs version [--json]   # "canondocs X.Y.Z", or canonical JSON
canondocs doctor             # built-in self-check
```

### Input format

`--from auto` (the default) selects the format from the file name:

| Input | Format |
| --- | --- |
| `*.yaml`, `*.yml` (any case) | YAML |
| `*.ndjson`, `*.jsonl` (any case), or `--ndjson-array` | NDJSON |
| anything else, `-`, or stdin | JSON |

Stdin is never treated as YAML unless `--from yaml` is given.
`--from ndjson` implies `--ndjson-array`.

Usage errors (exit 2):

- `--check` with YAML or NDJSON input (only JSON input can already be
  canonical);
- `--allow-merge-keys` without YAML input;
- `--head` without NDJSON input, or `--head 0`;
- `--ndjson-array` with `--from json`, `--from yaml`, or a YAML file name;
- more than one of `--check`, `--digest`, `--vector` (`--check --sort-set`
  on JSON checks that the array is a canonical set);
- a numeric option that is not plain ASCII decimal digits (no sign, space or
  underscore), or an unknown or repeated option.

### Limits

| Option | Default | Applies to |
| --- | --- | --- |
| `--max-bytes N` | 16777216 | input size (the input only, never the output) |
| `--max-depth N` | 64 | array/object nesting (outermost container is depth 1) |
| `--max-object-members N` | 65536 | members in one object / entries in one mapping |
| `--max-string-bytes N` | 4194304 | decoded bytes of one string or key |

At most `max-bytes + 1` bytes are read from a file or stdin; with
`--ndjson-array --head N`, reading stops after the N-th line, so the answer
does not wait for the rest of the stream. YAML input is additionally limited
to 255 levels of nesting, two documents, and the yamlprims default node and
alias budgets, which bound the size of the projected JSON (an alias-expansion
bomb is `too_large`).

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success (`--check`: input is canonical); a closed stdout pipe also counts as success |
| 1 | input refused, or `--check` found it not canonical |
| 2 | usage error |
| 4 | input could not be read |
| 5 | output could not be written |

Data is written to stdout only. Diagnostics go to stderr:

```
canondocs: jcs/rfc8785: <code> at byte <n>    # JSON and NDJSON input
canondocs: yaml: <code>: <message>            # YAML input
```

## JSON and NDJSON input

JSON and NDJSON input are canonicalized by canonprims exactly as its `jcs`
scheme defines, including its number rule: an integer token is admitted when
its exact value is a binary64 value (so `9007199254740992` is admitted and
`9007199254740993` is refused with `integer_outside_binary64`). NDJSON lines
must each end with LF, with no CR LF and no blank lines.

## YAML input

A YAML document is projected onto I-JSON (RFC 7493) under six rules, then
canonicalized under RFC 8785. Every rule fails closed.

1. **One document.** The stream holds exactly one document. A stream with no
   document (empty, whitespace, comments only) is `empty_stream`; more than
   one is `multi_document_stream`. An explicit empty document (`---`) or an
   explicit `null` / `~` is JSON `null`.
2. **Safe integers.** Integers lie in `-(2^53-1)` .. `2^53-1`; anything else
   (including `±2^53`, the 64-bit extremes and `2^64`) is
   `integer_outside_ijson`. This is stricter than the JSON number rule above,
   so that two distinct YAML integers never map to the same JSON number.
3. **Finite floats.** `.nan`, `.inf`, `-.inf` and out-of-range floats are
   `non_finite_number`. `-0.0` becomes `0` and `1.0` becomes `1`.
4. **String keys.** Every mapping key resolves to a string; boolean, integer,
   float, null, sequence and mapping keys are `non_string_key`. Repeated keys
   are `duplicate_key`.
5. **Tags and merge keys.** Core Schema tags (`!!str`, `!!int`, `!!float`,
   `!!bool`, `!!null`, `!!seq`, `!!map`) resolve normally; any other tag is
   `unsupported_tag`. A `<<` merge key is `merge_key_rejected` unless
   `--allow-merge-keys` is given, which applies it. A quoted `"<<"` is an
   ordinary string key.
6. **Unicode and limits.** The 66 Unicode noncharacters (U+FDD0..U+FDEF and
   U+nFFFE / U+nFFFF in every plane) are `noncharacter` in keys and values.
   Limits give `too_deep` and `too_large`.

Ill-formed UTF-8 is `invalid_utf8`. Any other YAML error (syntax, undefined
alias, a Core tag whose value does not match) is `invalid_yaml`. Anchors and aliases are expanded;
the result is plain data.

Conformance vectors for these rules are in
[`testdata/yaml-jcs-rfc8785-v0`](testdata/yaml-jcs-rfc8785-v0): `cases.json`
lists each input file with either its canonical output and SHA-256 or its
refusal code. An optional `options` member (`{"allow_merge_keys": true}`)
gives the CLI options for a case.

## Development

```sh
make check   # gofmt, go vet, go test, content check
make build   # CGO_ENABLED=0 binary in bin/
```

`CANONDOCS_CRUCIBLE_DIR`, when set to a crucible checkout, enables a
differential test of NDJSON prefix digests against its reference
canonicalizer (requires `python3`).

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at
your option. See [NOTICE](NOTICE).
