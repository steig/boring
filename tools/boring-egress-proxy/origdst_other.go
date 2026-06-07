//go:build !linux

package main

import (
	"errors"
	"net"
)

// originalDst is unavailable off Linux: SO_ORIGINAL_DST is a netfilter feature.
// On macOS dev hosts use `--upstream=sni` to exercise the proxy without
// transparent redirection.
func originalDst(_ *net.TCPConn) (string, error) {
	return "", errors.New("boring-egress: transparent mode (SO_ORIGINAL_DST) is Linux-only; use --upstream=sni for local prototyping")
}
