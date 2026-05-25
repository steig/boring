# Makefile for boring-proxy (ARD-0021).
# Targets: build (binary), test (go test), clean, fmt.

BINARY := boring-proxy
GOFLAGS ?=

.PHONY: build test test-race clean fmt vet all

all: build

build:
	go build $(GOFLAGS) -o $(BINARY) .

test:
	go test $(GOFLAGS) ./...

# test-race: race detector + no cache. Per security review (regression bar).
test-race:
	go test -race -count=1 $(GOFLAGS) ./...

vet:
	go vet ./...

fmt:
	go fmt ./...

clean:
	rm -f $(BINARY)
