# SPDX-License-Identifier: MIT OR Apache-2.0

VERSION := $(shell cat VERSION)
LDFLAGS := -s -w -X github.com/3leaps/canondocs/internal/cli.Version=$(VERSION)

.PHONY: check fmt fmt-check vet test content-check build

check: fmt-check vet test content-check

fmt:
	gofmt -w .

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet:
	go vet ./...

test:
	go test ./...

content-check:
	sh scripts/content-check.sh

build:
	mkdir -p bin
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/canondocs ./cmd/canondocs
