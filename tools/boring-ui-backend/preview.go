// preview.go — reverse-proxy for the right-pane preview iframe (ARD-0031, ARD-0033).
//
// The preview proxy forwards requests to the configured PreviewURL (the
// --preview-url flag value), stripping iframe-blocking headers (X-Frame-Options
// + CSP frame-ancestors) so production-shaped upstreams (Shopify, GitHub-style
// dev URLs, anything that defaults to clickjacking defenses) render inside the
// chat UI's iframe.
//
// DEDICATED ORIGIN, NOT A SUB-PATH (ARD-0033): this handler is mounted at the
// ROOT ("/") of its own host port — NOT under /preview/ on the shared proxy.
// ARD-0031 originally proxied under a same-origin sub-path, but real upstreams
// (Shopify storefronts) emit ROOT-ABSOLUTE asset URLs (/cdn/..., /checkouts/...,
// /web-pixels@.../) that escape any sub-path prefix and resolve to the shared
// proxy root, where they 404 (text/plain) with frame-ancestors 'none'. Serving
// the preview at its own origin root means those root-absolute URLs resolve back
// into THIS proxy and forward correctly. The cross-origin cost (SameSite cookies
// not flowing into the iframe) is acceptable for a dev preview — see ARD-0033.
//
// WebSocket upgrade is preserved automatically by httputil.ReverseProxy when
// both client and upstream negotiate Upgrade: websocket — Vite, Next, Rails
// (Hotwire), Shopify theme hot-reload, etc. all rely on this for HMR.
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
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
)

// newPreviewProxyHandler builds the root-mounted reverse proxy for the preview
// iframe's dedicated origin (ARD-0033). It forwards every path verbatim to
// previewURL with X-Frame-Options and CSP frame-ancestors stripped.
//
// Mounted at "/" (no prefix to strip), so GET /cdn/x.css forwards to
// previewURL + /cdn/x.css — which is exactly what makes Shopify's root-absolute
// asset URLs resolve. httputil.ReverseProxy's SetURL joins the inbound path onto
// previewURL's path and preserves the query string.
//
// Returns an error if previewURL is empty or unparseable; callers (main.go) only
// start the preview listener when a non-empty PreviewURL is configured.
//
// If the upstream is unreachable (closed port, DNS failure, etc.), the handler
// responds 502 with an actionable body — exercised by
// TestPreviewProxy_502OnUpstreamUnreachable.
func newPreviewProxyHandler(previewURL string) (http.Handler, error) {
	if strings.TrimSpace(previewURL) == "" {
		return nil, fmt.Errorf("preview URL is empty")
	}
	target, err := url.Parse(previewURL)
	if err != nil {
		return nil, fmt.Errorf("invalid preview URL %q: %w", previewURL, err)
	}

	rp := &httputil.ReverseProxy{
		// Rewrite (Go 1.20+) replaces the older Director callback. SetURL
		// copies scheme/host into pr.Out and joins the inbound path onto
		// target.Path — no manual prefix stripping, because we're root-mounted.
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// Upstream expects its own host header (vhost-routed services
			// like Shopify storefronts depend on this for routing). The
			// stdlib's default would have left this as the inbound Host
			// (our proxy's host), which is wrong.
			pr.Out.Host = target.Host
			// Ask the upstream for an identity (uncompressed) body so
			// ModifyResponse can inject the nav script into HTML without
			// gzip/br decompression. If the upstream compresses anyway,
			// injectNavScript detects it and skips injection (no corruption).
			pr.Out.Header.Del("Accept-Encoding")
		},
		ModifyResponse: previewModifyResponse,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			http.Error(w, "preview backend unreachable: "+err.Error(), http.StatusBadGateway)
		},
	}

	// Intercept the nav-script path locally; everything else proxies. A plain
	// HandlerFunc (not http.ServeMux) avoids ServeMux's path-cleaning redirects,
	// which would mangle proxied URLs. The "__boring_" prefix makes an upstream
	// path collision astronomically unlikely.
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == navScriptPath {
			serveNavScript(w, r)
			return
		}
		rp.ServeHTTP(w, r)
	}), nil
}

// navScriptPath is the proxy-origin path that serves navScript. Served from the
// preview origin so it satisfies a `script-src 'self'` CSP on the upstream.
const navScriptPath = "/__boring_nav.js"

// navScript reports the preview frame's current URL to the embedding chat UI so
// its address bar tracks navigation (ARD-0033 follow-up). The preview iframe is
// a different origin from the chat UI, so the parent can't read its location
// directly — this script (injected into proxied HTML) postMessages it up.
//
// Only the TOP preview frame reports: a nested sub-iframe (e.g. Shopify
// web-pixel sandboxes) has window.parent !== window.top, so it stays silent and
// never pollutes the bar. Cross-origin REFERENCE comparison (parent/top) is
// permitted; reading their properties is not, and we don't.
const navScript = `(function(){
  if (window === window.top || window.parent !== window.top) return;
  function report(){
    try {
      window.parent.postMessage(
        { source: "boring-preview", path: location.pathname + location.search + location.hash },
        "*"
      );
    } catch (e) {}
  }
  report();
  window.addEventListener("popstate", report);
  window.addEventListener("hashchange", report);
  ["pushState", "replaceState"].forEach(function(m){
    var orig = history[m];
    if (typeof orig === "function") {
      history[m] = function(){ var r = orig.apply(this, arguments); report(); return r; };
    }
  });
})();`

func serveNavScript(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.WriteString(w, navScript)
}

// previewModifyResponse is the ModifyResponse callback: strip frame-blocking
// headers (ARD-0031 §2) AND inject the nav script into HTML so the chat UI's
// address bar can track in-frame navigation.
func previewModifyResponse(resp *http.Response) error {
	if err := stripFrameBlockingHeaders(resp); err != nil {
		return err
	}
	return injectNavScript(resp)
}

// injectNavScript inserts <script src="/__boring_nav.js"> into HTML responses.
// No-op for non-HTML or still-compressed bodies. Rewrites Content-Length to
// match the grown body.
func injectNavScript(resp *http.Response) error {
	if !strings.HasPrefix(strings.ToLower(resp.Header.Get("Content-Type")), "text/html") {
		return nil
	}
	// We stripped Accept-Encoding outbound, so this should be identity. If the
	// upstream compressed anyway, don't corrupt the stream — skip injection.
	if enc := resp.Header.Get("Content-Encoding"); enc != "" && !strings.EqualFold(enc, "identity") {
		return nil
	}
	body, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		return err
	}

	ensureScriptSrcAllowsSelf(resp)

	out := insertBeforeFirstTag(body, []byte(`<script src="`+navScriptPath+`"></script>`),
		"</head>", "</body>", "</html>")
	resp.Body = io.NopCloser(bytes.NewReader(out))
	resp.ContentLength = int64(len(out))
	resp.Header.Set("Content-Length", strconv.Itoa(len(out)))
	resp.Header.Del("Content-Encoding") // body is identity now
	return nil
}

// insertBeforeFirstTag inserts ins before the first of the given closing tags
// (case-insensitive) found in body; if none are present, appends to the end.
func insertBeforeFirstTag(body, ins []byte, tags ...string) []byte {
	lower := bytes.ToLower(body)
	for _, tag := range tags {
		if i := bytes.Index(lower, []byte(tag)); i >= 0 {
			out := make([]byte, 0, len(body)+len(ins))
			out = append(out, body[:i]...)
			out = append(out, ins...)
			out = append(out, body[i:]...)
			return out
		}
	}
	return append(body, ins...)
}

// ensureScriptSrcAllowsSelf appends 'self' to a CSP script-src directive that
// lacks it, so the injected same-origin nav script can load. No-op when there's
// no CSP (e.g. Shopify theme dev sends none) or no script-src directive (scripts
// then fall back to default-src; we don't rewrite that so the page's own script
// policy is unchanged). Strict-dynamic/nonce CSPs that ignore 'self' degrade
// gracefully — the bar just won't track navigation for that upstream.
func ensureScriptSrcAllowsSelf(resp *http.Response) {
	csp := resp.Header.Values("Content-Security-Policy")
	if len(csp) == 0 {
		return
	}
	out := make([]string, 0, len(csp))
	for _, h := range csp {
		out = append(out, addSelfToScriptSrc(h))
	}
	resp.Header.Del("Content-Security-Policy")
	for _, h := range out {
		resp.Header.Add("Content-Security-Policy", h)
	}
}

func addSelfToScriptSrc(csp string) string {
	parts := strings.Split(csp, ";")
	for i, p := range parts {
		trimmed := strings.TrimSpace(p)
		name := trimmed
		if idx := strings.IndexAny(trimmed, " \t"); idx >= 0 {
			name = trimmed[:idx]
		}
		if strings.EqualFold(name, "script-src") {
			if !strings.Contains(trimmed, "'self'") {
				parts[i] = " " + trimmed + " 'self'"
			}
			break
		}
	}
	return strings.Join(parts, ";")
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
