package main

import (
	"bufio"
	"io"
	"os"
	"strings"
)

// Allowlist matches SNI hostnames against the per-profile egress allow file.
//
// Unlike the boot-time iptables enforcer (templates/_common/bin/install-egress),
// which resolves each hostname to a fixed set of IPs once and can't track
// CDN/anycast rotation, this matches on the hostname the client requested — so
// it works for BigQuery/Ads/Analytics/Shopify regardless of which IP the pool
// hands out (ARD-0034 #1). It also supports wildcards, which getent can't.
//
// Entry syntax (one per line; '#' comments and blanks ignored):
//
//	api.example.com      exact host
//	*.example.com        example.com itself AND any subdomain at any depth
//
// The wildcard is intentionally broader than a TLS cert wildcard (which matches
// one label): `*.googleapis.com` must cover bigquery.googleapis.com,
// oauth2.googleapis.com, storage.googleapis.com, etc., which is exactly the
// pattern these cloud APIs use.
type Allowlist struct {
	exact    map[string]struct{}
	suffixes []string // stored without leading dot, e.g. "googleapis.com"
}

// LoadAllowlist reads and parses the allow file at path.
func LoadAllowlist(path string) (*Allowlist, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ParseAllowlist(f), nil
}

// ParseAllowlist parses allow-file lines from r. It never errors: malformed
// lines are simply skipped, matching the enforcer's fail-toward-deny posture
// (an unparseable entry grants nothing rather than everything).
func ParseAllowlist(r io.Reader) *Allowlist {
	a := &Allowlist{exact: make(map[string]struct{})}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Tolerate a trailing "  # port N" annotation (the learn-mode proposer
		// in lib/egress.sh emits these).
		if i := strings.Index(line, "#"); i >= 0 {
			line = strings.TrimSpace(line[:i])
			if line == "" {
				continue
			}
		}
		host := strings.ToLower(strings.TrimSuffix(line, "."))
		if strings.HasPrefix(host, "*.") {
			suf := host[2:]
			if suf != "" {
				a.suffixes = append(a.suffixes, suf)
			}
			continue
		}
		a.exact[host] = struct{}{}
	}
	// Best-effort by design: a read error on the allow file yields whatever was
	// parsed so far (fail toward deny), so the scanner error is informational.
	_ = sc.Err()
	return a
}

// Allowed reports whether host is permitted. The match is case-insensitive and
// ignores a trailing dot (FQDN form).
func (a *Allowlist) Allowed(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}
	if _, ok := a.exact[host]; ok {
		return true
	}
	for _, suf := range a.suffixes {
		if host == suf || strings.HasSuffix(host, "."+suf) {
			return true
		}
	}
	return false
}
