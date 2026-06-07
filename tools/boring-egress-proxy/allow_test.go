package main

import (
	"strings"
	"testing"
)

func TestAllowlist(t *testing.T) {
	a := ParseAllowlist(strings.NewReader(`
# warehouse egress allowlist
api.stripe.com
*.googleapis.com
*.myshopify.com
EXAMPLE.COM
    *.internal.corp    # port 5432
`))

	allowed := []string{
		"api.stripe.com",
		"bigquery.googleapis.com",  // wildcard, one label
		"oauth2.googleapis.com",    // wildcard, sibling host
		"storage.googleapis.com",   // wildcard, BQ extract host
		"googleapis.com",           // wildcard base itself
		"shop.myshopify.com",       // per-store subdomain
		"example.com",              // case-insensitive exact
		"EXAMPLE.COM",              // input case-insensitive
		"bigquery.googleapis.com.", // trailing-dot FQDN
		"db.internal.corp",         // wildcard with trailing annotation stripped
	}
	for _, h := range allowed {
		if !a.Allowed(h) {
			t.Errorf("expected %q to be allowed", h)
		}
	}

	denied := []string{
		"evil.com",
		"notgoogleapis.com",          // must not match *.googleapis.com by accident
		"googleapis.com.evil.com",    // suffix-confusion attempt
		"api-stripe.com",             // near-miss on exact
		"",                           // empty
		"myshopify.com.attacker.net", // suffix-confusion attempt
	}
	for _, h := range denied {
		if a.Allowed(h) {
			t.Errorf("expected %q to be denied", h)
		}
	}
}

func TestAllowlist_Empty(t *testing.T) {
	a := ParseAllowlist(strings.NewReader("# nothing but comments\n\n"))
	if a.Allowed("anything.com") {
		t.Error("empty allowlist must deny everything")
	}
}
