// Command boring-egress-proxy is a PROTOTYPE SNI-aware egress filter (ARD-0034).
//
// It demonstrates the successor to the boot-time iptables IP-pinning enforcer
// (templates/_common/bin/install-egress): instead of resolving allowlist
// hostnames to fixed IPs once at container start — which can't track the
// CDN/anycast/rotating-IP cloud APIs a data-warehouse project hits (BigQuery,
// Google Ads, Analytics, Shopify Admin) — this peeks the plaintext TLS SNI on
// each new connection and filters on the requested hostname, with wildcard
// support. No TLS interception: it reads the ClientHello's server_name and then
// splices the encrypted bytes through untouched.
//
// Production deployment (Linux, in-container): an iptables REDIRECT rule sends
// outbound :443 to this proxy's listen port; the proxy recovers the real
// destination via SO_ORIGINAL_DST (transparent mode). For local prototyping on
// any OS, run with --upstream=sni and point a client at the listen port.
//
// This is a prototype: it covers TCP/TLS (:443-style) only. Plain HTTP, non-TLS
// protocols, QUIC/UDP, and IPv6 SO_ORIGINAL_DST are out of scope here and are
// tracked in ARD-0034's implementation order.
package main

import (
	"flag"
	"log"
	"net"
	"os"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8443", "address to listen on")
	allowFile := flag.String("allow-file", "/etc/boring/egress.allow", "path to the egress allowlist (one host per line; * wildcard supported)")
	upstream := flag.String("upstream", "original", "where to forward: \"original\" (transparent, SO_ORIGINAL_DST, Linux) or \"sni\" (dial the requested host; for local prototyping)")
	upstreamPort := flag.String("upstream-port", "443", "port to dial in --upstream=sni mode")
	flag.Parse()

	allow, err := LoadAllowlist(*allowFile)
	if err != nil {
		log.Fatalf("boring-egress: cannot read allow file %s: %v", *allowFile, err)
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("boring-egress: listen %s: %v", *listen, err)
	}

	log.SetOutput(os.Stderr)
	log.Printf("boring-egress (PROTOTYPE, ARD-0034): listening on %s, upstream=%s, allow-file=%s", *listen, *upstream, *allowFile)

	s := &Server{
		Allow:        allow,
		Upstream:     *upstream,
		UpstreamPort: *upstreamPort,
		DialTimeout:  10 * time.Second,
	}
	if err := s.Serve(ln); err != nil {
		log.Fatalf("boring-egress: serve: %v", err)
	}
}
