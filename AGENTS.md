# AGENTS.md

Guidance for automated contributors to canondocs. Read local guidance if
present.

## Build and test

```sh
make check   # gofmt check, go vet, go test, content check
make build   # CGO_ENABLED=0 binary in bin/canondocs
make fmt     # gofmt -w
```

## Layout

| Path | Contents |
| --- | --- |
| `cmd/canondocs` | `main`: wires the process to `internal/cli` |
| `internal/cli` | argument parsing, I/O, exit codes, subcommands |
| `internal/yamljcs` | YAML to I-JSON projection and its refusal codes |
| `testdata/yaml-jcs-rfc8785-v0` | YAML conformance vectors (`cases.json` index) |
| `scripts/content-check.sh` | public-surface content check run by `make check` |

## Rules

- Standard library only, besides `github.com/3leaps/canonprims` and
  `github.com/3leaps/yamlprims`. No cgo.
- Data on stdout only; diagnostics on stderr. Exit codes 0/1/2/4/5 as
  documented in `README.md`.
- Expected values in conformance vectors are derived from RFC 8785 and the
  projection rules, never copied from canondocs output.
- No absolute or home-directory paths in committed files; tests read
  external directories only through environment variables.
