# AGENTS.md

Guidance for automated contributors to canondocs. Read local guidance if
present.

## Build and test

```sh
make check   # gofmt check, go vet, go test, content check
make build   # CGO_ENABLED=0 binary in bin/canondocs
make fmt     # gofmt -w
make release-tooling-test   # release tooling suites (throwaway keys only)
```

## Layout

| Path | Contents |
| --- | --- |
| `cmd/canondocs` | `main`: wires the process to `internal/cli` |
| `internal/cli` | argument parsing, I/O, exit codes, subcommands |
| `internal/yamljcs` | YAML to I-JSON projection and its refusal codes |
| `testdata/yaml-jcs-rfc8785-v0` | YAML conformance vectors (`cases.json` index) |
| `scripts/content-check.{sh,py}` | content checks run by `make check` |
| `scripts/release-*`, `config/release/` | release, provenance and registry verification tooling; each script has a `*.test.sh` suite listed in `config/release/tooling-suites.txt` |
| `docs/security/`, `keys/` | public release pins and fingerprint anchors |

## Rules

- Standard library only, besides `github.com/3leaps/canonprims` and
  `github.com/3leaps/yamlprims`. No cgo.
- Data on stdout only; diagnostics on stderr. Exit codes 0/1/2/4/5 as
  documented in `README.md`.
- Expected values in conformance vectors are derived from RFC 8785 and the
  projection rules, never copied from canondocs output.
- Release tooling suites use synthetic fixtures and throwaway keys only; they
  never read the committed pins, use the network, or sign with real keys.
- After editing `.github/workflows/`, run
  `python3 scripts/release-workflow-pin.py update`.
- No absolute or home-directory paths in committed files; tests read
  external directories only through environment variables.
