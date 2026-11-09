# SPDX-License-Identifier: MIT OR Apache-2.0

BINARY_NAME := canondocs
VERSION := $(shell cat VERSION 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/3leaps/canondocs/internal/cli.Version=$(VERSION)
GOBUILD := CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)"
DIST_RELEASE ?= dist/release
DIST_PUBLISHED ?= dist/published
REGISTRY ?= all
DOCTOR_SCOPE ?= dev

.PHONY: pr-final check fmt fmt-check vet test content-check host-path-check surface-scan surface-scan-release doctor build build-all
.PHONY: release-workflow-check release-anchors-check release-provenance-check release-tooling-test release-tag-tests
.PHONY: release-clean release-build release-checksums release-verify-checksums release-github-preflight release-preflight
.PHONY: release-guard-tag-name release-guard-tag-version release-guard-signing-tag release-prepare-tag-message release-tag
.PHONY: release-push-tag release-verify-tag release-verify-published-tag release-verify-remote-tag release-export-pin
.PHONY: release-validate-pin release-insert-anchors release-download release-create-draft release-sign release-export-keys
.PHONY: release-verify-keys release-verify-signatures release-notes release-upload release-upload-provenance
.PHONY: release-upload-all release-publish release-post-tag-selector release-record-anchor release-stage-published
.PHONY: release-verify-registries

## Development

check: fmt-check vet test content-check release-workflow-check  ## gofmt, vet, tests, content and workflow-pin checks

fmt:  ## gofmt -w
	gofmt -w .

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet:
	go vet ./...

test:
	go test ./...

content-check:  ## Committed files: home paths, keys, tokens, commit markers, non-public identifiers
	@sh scripts/content-check.sh
	@python3 -I -B ./scripts/content-check.py

host-path-check:  ## Build-host path embedding checks
	@./scripts/host-path-check.test.sh

surface-scan: content-check  ## Public-surface scan (skips the catalog tier when LIMENSAFE_CATALOG_PATH is unset)
	@./scripts/surface-scan.sh

surface-scan-release: content-check  ## Release-mode public-surface scan (requires the external catalog)
	@CANONDOCS_SURFACE_SCAN_REQUIRED=1 CANONDOCS_SURFACE_SCOPE=release ./scripts/surface-scan.sh

pr-final: check host-path-check surface-scan build-all  ## Final non-mutating gate before a release PR or tag

doctor:  ## Verify required host tools and minimum versions (DOCTOR_SCOPE=dev|release)
	@./scripts/doctor.sh "$(DOCTOR_SCOPE)"

build:  ## CGO_ENABLED=0 binary in bin/
	mkdir -p bin
	$(GOBUILD) -o bin/$(BINARY_NAME) ./cmd/$(BINARY_NAME)

build-all:  ## Every release target into bin/ (convenience; releases use release-build)
	mkdir -p bin
	GOOS=darwin GOARCH=arm64 $(GOBUILD) -o bin/$(BINARY_NAME)-darwin-arm64 ./cmd/$(BINARY_NAME)
	GOOS=linux GOARCH=amd64 $(GOBUILD) -o bin/$(BINARY_NAME)-linux-amd64 ./cmd/$(BINARY_NAME)
	GOOS=linux GOARCH=arm64 $(GOBUILD) -o bin/$(BINARY_NAME)-linux-arm64 ./cmd/$(BINARY_NAME)
	GOOS=windows GOARCH=amd64 $(GOBUILD) -o bin/$(BINARY_NAME)-windows-amd64.exe ./cmd/$(BINARY_NAME)
	GOOS=windows GOARCH=arm64 $(GOBUILD) -o bin/$(BINARY_NAME)-windows-arm64.exe ./cmd/$(BINARY_NAME)

## Release provenance checks

release-workflow-check:  ## Workflow pins and the read-only release workflow
	@python3 -B -E ./scripts/release-workflow-pin.py check
	@./scripts/release-workflow-permissions.test.sh

release-anchors-check:  ## Committed public keys against both fingerprint anchors (needs gpg, CANONDOCS_DECERNOR_BIN)
	@./scripts/release-verify-committed-anchors.sh
	@./scripts/validate-release-anchors.sh

release-provenance-check: release-workflow-check release-anchors-check  ## Workflow pins plus committed release anchors

release-tooling-test:  ## Run every release and surface-hygiene tooling suite (throwaway keys only)
	@./scripts/release-tooling-test.sh

release-tag-tests: release-tooling-test  ## Signed-tag tooling tests (needs gpg, git, python3, jq, minisign, make, decernor)
	@echo "[ok] signed-tag tooling tests passed"

## Release ceremony (maintainer-run)
#
# Manifests are signed, not individual artifacts. Environment (CANONDOCS_ prefix):
#   CANONDOCS_RELEASE_TAG  - release tag, e.g. v0.1.0
#   CANONDOCS_DECERNOR_BIN - absolute path to decernor >= 0.1.8 (ceremony)
#   CANONDOCS_MINISIGN_KEY - path to the minisign secret key
#   CANONDOCS_MINISIGN_PUB - path to the minisign public key (one-time pin bootstrap only)
#   CANONDOCS_PGP_KEY_ID   - gpg signing-subkey selector (<subkey>!)
#   CANONDOCS_GPG_HOMEDIR  - isolated gpg homedir (0700, outside the repo)
#
# The release tag comes only from CANONDOCS_RELEASE_TAG. It never defaults to
# v$(VERSION), and the generic RELEASE_TAG name is refused from any source
# (environment, command line or file) before any release recipe or
# prerequisite runs, including under make -n. Post-tag targets also bind to
# the checked-out VERSION: run the ceremony from a checkout of the tagged commit.
ifneq ($(origin RELEASE_TAG),undefined)
ifneq ($(filter release-%,$(MAKECMDGOALS)),)
$(error RELEASE_TAG is forbidden (origin: $(origin RELEASE_TAG)); unset it and set CANONDOCS_RELEASE_TAG=vX.Y.Z)
endif
endif

release-clean:  ## Reset dist/release and dist/published staging
	@rm -rf "$(DIST_RELEASE)" "$(DIST_RELEASE).anchor" "$(DIST_PUBLISHED)" "$(DIST_PUBLISHED).anchor"
	@mkdir -p "$(DIST_RELEASE)"
	@echo "[ok] cleaned $(DIST_RELEASE) and $(DIST_PUBLISHED)"

release-build: release-clean  ## Build the five raw release binaries and checksums into dist/release
	@mkdir -p "$(DIST_RELEASE)"
	@GOOS=darwin GOARCH=arm64 $(GOBUILD) -o "$(DIST_RELEASE)/$(BINARY_NAME)-darwin-arm64" ./cmd/$(BINARY_NAME)
	@GOOS=linux GOARCH=amd64 $(GOBUILD) -o "$(DIST_RELEASE)/$(BINARY_NAME)-linux-amd64" ./cmd/$(BINARY_NAME)
	@GOOS=linux GOARCH=arm64 $(GOBUILD) -o "$(DIST_RELEASE)/$(BINARY_NAME)-linux-arm64" ./cmd/$(BINARY_NAME)
	@GOOS=windows GOARCH=amd64 $(GOBUILD) -o "$(DIST_RELEASE)/$(BINARY_NAME)-windows-amd64.exe" ./cmd/$(BINARY_NAME)
	@GOOS=windows GOARCH=arm64 $(GOBUILD) -o "$(DIST_RELEASE)/$(BINARY_NAME)-windows-arm64.exe" ./cmd/$(BINARY_NAME)
	@$(MAKE) release-checksums
	@echo "[ok] release build complete"

release-checksums:  ## Generate SHA256SUMS and SHA512SUMS in dist/release
	@./scripts/generate-checksums.sh "$(DIST_RELEASE)" "$(BINARY_NAME)"

release-verify-checksums:  ## Verify SHA256SUMS / SHA512SUMS match the artifacts
	@./scripts/verify-checksums.sh "$(DIST_RELEASE)"

release-github-preflight:  ## Verify the remote tag-protection ruleset and immutable releases
	@./scripts/release-github-preflight.sh

release-preflight:  ## Pre-tag gate: clean synced main, notes, pins, dates, release surface scan
	@./scripts/release-verify-committed-anchors.sh
	@$(MAKE) surface-scan-release
	@./scripts/release-preflight.sh

release-guard-tag-name:  ## Guard: CANONDOCS_RELEASE_TAG set and canonical vX.Y.Z
	@if [ -z "$(CANONDOCS_RELEASE_TAG)" ]; then \
		echo "error: CANONDOCS_RELEASE_TAG not set (example: CANONDOCS_RELEASE_TAG=v$(VERSION))." >&2; \
		exit 1; \
	fi
	@printf '%s\n' "$(CANONDOCS_RELEASE_TAG)" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$' || { \
		echo "error: CANONDOCS_RELEASE_TAG must be canonical vX.Y.Z" >&2; exit 1; }
	@echo "[ok] release tag name $(CANONDOCS_RELEASE_TAG) is canonical"

release-guard-tag-version:  ## Guard: CANONDOCS_RELEASE_TAG canonical and matching VERSION and the built-in version
	@if [ -z "$(CANONDOCS_RELEASE_TAG)" ]; then \
		echo "error: CANONDOCS_RELEASE_TAG not set (example: CANONDOCS_RELEASE_TAG=v$(VERSION))." >&2; \
		exit 1; \
	fi
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-guard-tag-version.sh
	@grep -Eq '^var Version = "$(VERSION)"$$' internal/cli/cli.go || { \
		echo "error: internal/cli/cli.go Version does not match VERSION ($(VERSION))" >&2; exit 1; }

release-guard-signing-tag: release-guard-tag-version  ## Guard: CANONDOCS_RELEASE_TAG matches VERSION
	@:

release-prepare-tag-message:  ## Maintainer-only: prepare and review the external per-cut tag message
	@./scripts/release-tag-operator.sh prepare-message

release-tag:  ## Maintainer-only: create and verify a local signed version tag (no push)
	@./scripts/release-tag-operator.sh local-tag

release-push-tag:  ## Maintainer-only: publish and verify the signed version tag
	@./scripts/release-tag-operator.sh remote-push

release-verify-tag:  ## Verify the local tag using only the committed public pin
	@./scripts/release-verify-tag.sh

release-verify-published-tag: release-guard-tag-name  ## Verify the published tag object and signature against its committed pin
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh

release-verify-remote-tag:  ## Compare local and remote tag objects and GitHub verification
	@./scripts/release-verify-remote-tag.sh

release-export-pin:  ## Maintainer-only: export the approved public key when no pin exists
	@./scripts/release-export-pin.sh

release-validate-pin:  ## Maintainer-only: read-only validation of the existing public pin
	@./scripts/release-validate-pin.sh

release-insert-anchors: release-validate-pin  ## Maintainer-only: validate pin, then generate absent public anchors
	@./scripts/release-insert-anchors.sh

release-download: release-guard-tag-version  ## Download CI-built artifacts for the verified tag (workflow artifact)
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh
	@./scripts/release-fetch-ci-artifacts.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-create-draft: release-guard-tag-version release-verify-checksums  ## Create the draft release from verified local artifacts
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh
	@./scripts/release-create-draft.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-sign: release-guard-tag-version  ## Maintainer-only: sign checksum manifests with minisign and PGP
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh
	@./scripts/sign-release-manifests.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-export-keys: release-guard-tag-version  ## Stage public signing keys from the verified tagged commit
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh
	@./scripts/release-stage-tagged-pubkeys.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-verify-keys:  ## Verify both exported public keys and fingerprint anchors are present and public-only
	@[ -f "$(DIST_RELEASE)/$(BINARY_NAME)-minisign.pub" ] || { echo "error: missing $(DIST_RELEASE)/$(BINARY_NAME)-minisign.pub; run make release-export-keys" >&2; exit 1; }
	@[ -f "$(DIST_RELEASE)/$(BINARY_NAME)-release-signing-key.asc" ] || { echo "error: missing $(DIST_RELEASE)/$(BINARY_NAME)-release-signing-key.asc; run make release-export-keys" >&2; exit 1; }
	@[ -f "$(DIST_RELEASE)/expected-fingerprints.txt" ] || { echo "error: missing $(DIST_RELEASE)/expected-fingerprints.txt; run make release-export-keys" >&2; exit 1; }
	@[ -f "$(DIST_RELEASE)/expected-fingerprints.ndjson" ] || { echo "error: missing $(DIST_RELEASE)/expected-fingerprints.ndjson; run make release-export-keys" >&2; exit 1; }
	@./scripts/verify-minisign-public-key.sh "$(DIST_RELEASE)/$(BINARY_NAME)-minisign.pub"
	@./scripts/verify-public-key.sh "$(DIST_RELEASE)/$(BINARY_NAME)-release-signing-key.asc"

release-verify-signatures:  ## Verify all four manifest signatures and both public keys (fail closed)
	@./scripts/release-verify-signatures.sh "$(DIST_RELEASE)"

release-notes: release-guard-tag-version  ## Stage docs/releases/<tag>.md into dist/release
	@notes_src="docs/releases/$(CANONDOCS_RELEASE_TAG).md"; notes_dst="$(DIST_RELEASE)/release-notes-$(CANONDOCS_RELEASE_TAG).md"; \
	if [ ! -f "$$notes_src" ]; then echo "error: missing $$notes_src" >&2; exit 1; fi; \
	cp "$$notes_src" "$$notes_dst"; echo "[ok] copied $$notes_src to $$notes_dst"

release-upload: release-upload-provenance  ## Upload provenance assets (CANONDOCS_RELEASE_TAG=vX.Y.Z)
	@:

release-upload-provenance: release-guard-tag-version release-verify-checksums release-verify-keys release-verify-signatures  ## Upload manifests, signatures, keys and notes (no binaries)
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh
	@./scripts/release-upload-provenance.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-upload-all: release-guard-tag-version release-verify-checksums release-verify-keys release-verify-signatures  ## Upload binaries and provenance (manual override)
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-published-tag.sh
	@./scripts/release-upload.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-publish: release-guard-tag-version  ## Promote the draft after byte-verifying it against the local signed set
	@./scripts/release-publish.sh "$(CANONDOCS_RELEASE_TAG)" "$(DIST_RELEASE)"
	@echo "   View: https://github.com/3leaps/$(BINARY_NAME)/releases/tag/$(CANONDOCS_RELEASE_TAG)"

release-post-tag-selector:  ## Verify post-tag ceremony env vars (tag, primary, signing subkey!)
	@./scripts/release-post-tag-selector.sh

release-record-anchor: release-guard-tag-version  ## Verify the published tag and record the external ceremony anchor
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-record-anchor.sh

release-stage-published: release-guard-tag-name  ## Clean-room download and verify the published immutable release
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-stage-published.sh "$(DIST_PUBLISHED)"

release-verify-registries: release-guard-tag-name  ## Verify Go proxy, Homebrew tap and Scoop bucket against the staged published release
	@CANONDOCS_RELEASE_TAG="$(CANONDOCS_RELEASE_TAG)" ./scripts/release-verify-registries.sh --directory "$(DIST_PUBLISHED)" --registry "$(REGISTRY)"
