// preview.go — reverse-proxy route for the right-pane iframe (ARD-0031).
//
// boring-ui-backend mounts /preview/* and forwards requests to the configured
// PreviewURL (the --preview-url flag value). Responses are minimally massaged
// to strip iframe-blocking headers (X-Frame-Options + CSP frame-ancestors)
// so production-shaped upstreams (Shopify, GitHub-style dev URLs, anything
// that defaults to clickjacking defenses) render inside the chat UI's iframe.
//
// Same-origin gains beyond just X-Frame-Options:
//   - Cookies set by the upstream are scoped to the proxy's origin, not the
//     upstream's, so the marketer's chat session and preview session share
//     one cookie jar.
//   - CSP frame-ancestors / Strict-Transport-Security cookie scoping /
//     SameSite=Strict tightening from 2026 spec churn all become non-issues
//     because chat + preview are one origin from the browser's perspective.
//
// WebSocket upgrade is preserved automatically by httputil.ReverseProxy when
// both client and upstream negotiate Upgrade: websocket — Vite, Next, Rails
// (Hotwire), Shopify theme-kit, etc. all rely on this for HMR.
//
// LOCAL-DEV-ONLY SAFETY BOUNDARY (READ BEFORE COPYING THIS CODE ELSEWHERE):
// Stripping X-Frame-Options + CSP frame-ancestors is contextually safe HERE
// because the user is iframing THEIR OWN local dev server — there is no
// attacker tricking them into framing a malicious site. In any other
// context (general-purpose proxy, web gateway, multi-tenant SaaS) stripping
// these headers RE-ENABLES the clickjacking class of attacks they exist to
// prevent. Do not copy stripFrameBlockingHeaders into a production-facing
// proxy without re-reading ARD-0031 §Rationale.
package main

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

// handlePreview reverse-proxies /preview/* to s.PreviewURL with X-Frame-Options
// and CSP frame-ancestors stripped. Per ARD-0031 §1.
//
// If s.PreviewURL is empty, returns 404 with a hint that no preview URL is
// configured for this project — matches the index-page fallback message so
// the user gets a consistent answer regardless of how they hit the proxy.
//
// If the upstream is unreachable (closed port, DNS failure, etc.), returns
// 502 with an actionable error body. The error path is exercised by
// TestHandlePreview_502OnUpstreamUnreachable.
func (s *Server) handlePreview(w http.ResponseWriter, r *http.Request) {
	if s.PreviewURL == "" {
		http.Error(w, "no preview configured for this project", http.StatusNotFound)
		return
	}
	target, err := url.Parse(s.PreviewURL)
	if err != nil {
		http.Error(w, "invalid preview URL: "+err.Error(), http.StatusInternalServerError)
		return
	}

	rp := &httputil.ReverseProxy{
		// Rewrite (Go 1.20+) replaces the older Director callback. SetURL
		// copies scheme/host/path from target into pr.Out, after which we
		// overwrite the path with the de-prefixed version. Per ARD-0031 §1.
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// Upstream expects its own host header (vhost-routed services
			// like Shopify storefronts depend on this for routing). The
			// stdlib's default would have left this as the inbound Host
			// (our proxy's host), which is wrong.
			pr.Out.Host = target.Host
			// Strip the /preview prefix so the upstream sees its own URL
			// space. GET /preview/foo/bar -> upstream GET /foo/bar.
			pr.Out.URL.Path = strings.TrimPrefix(pr.In.URL.Path, "/preview")
			if pr.Out.URL.Path == "" {
				pr.Out.URL.Path = "/"
			}
		},
		ModifyResponse: stripFrameBlockingHeaders,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			http.Error(w, "preview backend unreachable: "+err.Error(), http.StatusBadGateway)
		},
	}
	rp.ServeHTTP(w, r)
}

// stripFrameBlockingHeaders is the ModifyResponse callback for the /preview/*
// reverse proxy. Per ARD-0031 §2.
//
// Removes:
//   - X-Frame-Options entirely (single-header, single-value, no nuance —
//     just delete it).
//   - The frame-ancestors directive from any Content-Security-Policy header,
//     preserving every other directive. If frame-ancestors was the ONLY
//     directive, the whole CSP header is deleted.
//
// Does NOT touch:
//   - Cross-Origin-Resource-Policy / Cross-Origin-Opener-Policy /
//     Cross-Origin-Embedder-Policy — these govern different cross-origin
//     contexts and don't usually block iframes by themselves. ARD-0031 §2
//     explicitly defers this until field evidence shows otherwise.
//   - Other CSP directives (script-src, style-src, default-src, etc.) —
//     these still protect against real XSS/injection risks the marketer's
//     dev preview should keep.
//
// SAFETY: this function MUST NOT be copied into a general-purpose proxy. It
// is safe HERE only because the user is iframing their own local dev server;
// in any other context it re-enables clickjacking. See file-level comment.
func stripFrameBlockingHeaders(resp *http.Response) error {
	// 1. Delete X-Frame-Options unconditionally. http.Header.Del is
	// case-insensitive (it canonicalizes the key first) so we don't need
	// to handle X-FRAME-OPTIONS vs x-frame-options vs X-Frame-Options.
	resp.Header.Del("X-Frame-Options")

	// 2. Surgically scrub frame-ancestors from CSP. We use Header.Values
	// rather than Get because CSP can be set multiple times — the spec
	// says the browser intersects all of them, so we must process each
	// one independently and rewrite the slice.
	csp := resp.Header.Values("Content-Security-Policy")
	if len(csp) == 0 {
		return nil
	}
	cleaned := make([]string, 0, len(csp))
	for _, h := range csp {
		stripped := removeFrameAncestorsDirective(h)
		if stripped != "" {
			cleaned = append(cleaned, stripped)
		}
	}
	if len(cleaned) == 0 {
		// All CSP headers consisted of only frame-ancestors — drop the
		// header entirely so the browser sees no CSP at all (rather than
		// an empty header value, which some browsers treat as "deny all").
		resp.Header.Del("Content-Security-Policy")
		return nil
	}
	// http.Header.Del + repeated Add is the only way to fully replace
	// multi-valued headers (Set only writes the first value).
	resp.Header.Del("Content-Security-Policy")
	for _, h := range cleaned {
		resp.Header.Add("Content-Security-Policy", h)
	}
	return nil
}

// removeFrameAncestorsDirective takes a single CSP header value, drops the
// frame-ancestors directive (case-insensitive match), and rejoins the rest.
// Returns the empty string if no directives remain after stripping.
//
// Splits on ";" because the CSP grammar separates directives with ";". Empty
// fragments (e.g. trailing ";" or "; ;") are dropped during the rebuild.
// Original ordering is preserved sans the dropped directive.
//
// Examples:
//
//	"default-src 'self'; frame-ancestors 'none'; script-src 'self'"
//	  -> "default-src 'self'; script-src 'self'"
//
//	"frame-ancestors 'none'"
//	  -> ""
//
//	"Frame-Ancestors 'none'; style-src 'unsafe-inline'"
//	  -> "style-src 'unsafe-inline'"
func removeFrameAncestorsDirective(csp string) string {
	parts := strings.Split(csp, ";")
	kept := make([]string, 0, len(parts))
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed == "" {
			continue
		}
		// Compare just the directive name (first whitespace-separated
		// token) case-insensitively. "frame-ancestors 'none'" -> name is
		// "frame-ancestors". This avoids substring-matching pitfalls
		// where e.g. a hypothetical "frame-ancestors-policy" directive
		// would also match.
		name := trimmed
		if idx := strings.IndexAny(trimmed, " \t"); idx >= 0 {
			name = trimmed[:idx]
		}
		if strings.EqualFold(name, "frame-ancestors") {
			continue
		}
		kept = append(kept, trimmed)
	}
	return strings.Join(kept, "; ")
}
