# boring-egress-proxy (PROTOTYPE — ARD-0034)

An SNI-aware egress filter: the proposed successor to the boot-time iptables
IP-pinning enforcer in `templates/_common/bin/install-egress`.

## Why

The current enforcer resolves each allowlisted hostname to a fixed set of IPs
**once at container boot** and pins `iptables -d <ip> ACCEPT` rules. That works
for a small, stable set of hosts (the Shopify dogfood) but cannot track the
CDN/anycast/rotating-IP services a data-warehouse project hits — BigQuery,
Google Ads, Google Analytics, the Shopify Admin API, cloud Postgres/MySQL —
whose DNS pools rotate within seconds. A long ETL run drifts off the pinned IPs
and starts hitting `REJECT` for no visible reason. See
[ARD-0034](../../docs/ards/ard-0034-external-api-and-warehouse-readiness-gaps.md)
findings #1, #2, #8, #10.

This proxy filters on the **hostname the client requested**, read from the
plaintext SNI in the TLS ClientHello — so it works regardless of which pool IP
DNS returns, and it supports **wildcards** (`*.googleapis.com`), which `getent`
can't. It does **no TLS interception**: it reads the `server_name` extension and
then splices the encrypted bytes through untouched. It never holds the client's
keys.

## How it filters

```
client ──TLS──▶ [iptables REDIRECT :443 → :8443] ──▶ boring-egress-proxy
                                                          │ peek ClientHello SNI
                                                          │ match allowlist (exact + *.wildcard)
                                                          ▼
                                              allow → dial original dest, splice
                                              deny  → close
```

In production (Linux, in-container) an `iptables`/`nft` REDIRECT rule sends
outbound `:443` to the proxy, which recovers the real destination via
`SO_ORIGINAL_DST` (`--upstream=original`, the default). For local prototyping on
any OS, run `--upstream=sni` and the proxy dials the requested host directly.

## Allowlist format

Same file as the iptables enforcer (`/etc/boring/egress.allow`), one host per
line, `#` comments and blanks ignored, with wildcard support added:

```
api.stripe.com          # exact host
*.googleapis.com         # googleapis.com itself and any subdomain at any depth
*.myshopify.com
```

The `*.` wildcard is deliberately broader than a TLS-cert wildcard (one label):
`*.googleapis.com` matches `bigquery.googleapis.com`, `oauth2.googleapis.com`,
`storage.googleapis.com`, etc. — the exact shape these APIs use.

## Run

```sh
make build
./boring-egress-proxy --listen 127.0.0.1:8443 --allow-file ./egress.allow --upstream=sni
```

## Test

```sh
make test       # SNI parser (against real crypto/tls ClientHellos) + matcher
make test-race  # concurrency check
```

## Prototype scope

Covers TCP/TLS (`:443`-style) only. **Out of scope** here and tracked in
ARD-0034's implementation order: plain HTTP / non-TLS protocols, QUIC/UDP, IPv6
`SO_ORIGINAL_DST`, the `iptables` REDIRECT wiring in the preset entrypoints, and
a fail-closed story for connections with no SNI. This module is not yet
referenced by `boring` or the preset Dockerfiles, but its `go test -race` runs
in CI (`.github/workflows/test.yml` `go-tests` matrix).
