# Makefile for boring-egress-proxy (ARD-0034 prototype).
# Targets: build (binary), test (go test), test-race, clean, fmt, vet.

BINARY := boring-egress-proxy
GOFLAGS ?=

.PHONY: build test test-race clean fmt vet all

all: build

build:
	go build $(GOFLAGS) -o $(BINARY) .

test:
	go test $(GOFLAGS) ./...

# test-race: race detector + no cache (the proxy is concurrent per-connection).
test-race:
	go test -race -count=1 $(GOFLAGS) ./...

vet:
	go vet ./...

fmt:
	go fmt ./...

clean:
	rm -f $(BINARY)
