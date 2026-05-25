# Makefile for boring-ui-backend (ARD-0022 §3 — in-container chat backend).
# Targets: build (binary), test (go test), test-race, clean, fmt, vet.

BINARY := boring-ui-backend
GOFLAGS ?=

.PHONY: build test test-race clean fmt vet all

all: build

build:
	go build $(GOFLAGS) -o $(BINARY) .

test:
	go test $(GOFLAGS) ./...

# test-race: race detector + no cache. Mirror boring-proxy's discipline.
test-race:
	go test -race -count=1 $(GOFLAGS) ./...

vet:
	go vet ./...

fmt:
	go fmt ./...

clean:
	rm -f $(BINARY)
