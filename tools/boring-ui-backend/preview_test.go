// preview_test.go — tests for the /preview/* reverse-proxy route and the
// frame-blocking-header-strip helpers (ARD-0031).
//
// All upstreams are mocked with net/http/httptest. NO live invocation of
// Shopify, claude, or docker — same project rule that applies everywhere.
//
// WebSocket test note: this file uses stdlib net only — no
// golang.org/x/net/websocket. The test verifies the HTTP-layer Upgrade
// handshake (101 Switching Protocols + Connection/Upgrade header echo +
// post-upgrade bidirectional byte forwarding), which is what
// httputil.ReverseProxy is actually responsible for. The WS framing layer
// above that is the application's concern, not the proxy's.
package main

import (
	"bufio"
	"compress/gzip"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

// --- stripFrameBlockingHeaders unit tests -----------------------------------

func TestStripFrameBlockingHeaders_RemovesXFrameOptions(t *testing.T) {
	resp := &http.Response{Header: http.Header{}}
	resp.Header.Set("X-Frame-Options", "DENY")

	if err := stripFrameBlockingHeaders(resp); err != nil {
		t.Fatalf("strip: %v", err)
	}
	if got := resp.Header.Get("X-Frame-Options"); got != "" {
		t.Errorf("X-Frame-Options not removed: got %q", got)
	}
}

func TestStripFrameBlockingHeaders_RemovesOnlyFrameAncestors(t *testing.T) {
	resp := &http.Response{Header: http.Header{}}
	resp.Header.Set("Content-Security-Policy",
		"default-src 'self'; frame-ancestors 'none'; script-src 'self'")

	if err := stripFrameBlockingHeaders(resp); err != nil {
		t.Fatalf("strip: %v", err)
	}
	got := resp.Header.Get("Content-Security-Policy")
	if strings.Contains(got, "frame-ancestors") {
		t.Errorf("frame-ancestors not removed; got %q", got)
	}
	if !strings.Contains(got, "default-src 'self'") {
		t.Errorf("default-src dropped; got %q", got)
	}
	if !strings.Contains(got, "script-src 'self'") {
		t.Errorf("script-src dropped; got %q", got)
	}
}

func TestStripFrameBlockingHeaders_DeletesEmptyCSP(t *testing.T) {
	// When frame-ancestors is the only directive in CSP, the whole header
	// should be deleted (sending an empty CSP is interpreted as "deny all"
	// by some browsers — strictly worse than no CSP).
	resp := &http.Response{Header: http.Header{}}
	resp.Header.Set("Content-Security-Policy", "frame-ancestors 'none'")

	if err := stripFrameBlockingHeaders(resp); err != nil {
		t.Fatalf("strip: %v", err)
	}
	if _, ok := resp.Header["Content-Security-Policy"]; ok {
		t.Errorf("CSP header should be deleted entirely; got %q",
			resp.Header.Get("Content-Security-Policy"))
	}
}

func TestStripFrameBlockingHeaders_FrameAncestorsCaseInsensitive(t *testing.T) {
	resp := &http.Response{Header: http.Header{}}
	resp.Header.Set("Content-Security-Policy",
		"default-src 'self'; Frame-Ancestors 'none'; script-src 'self'")

	if err := stripFrameBlockingHeaders(resp); err != nil {
		t.Fatalf("strip: %v", err)
	}
	got := resp.Header.Get("Content-Security-Policy")
	if strings.Contains(strings.ToLower(got), "frame-ancestors") {
		t.Errorf("mixed-case Frame-Ancestors not removed; got %q", got)
	}
	if !strings.Contains(got, "default-src 'self'") {
		t.Errorf("default-src dropped; got %q", got)
	}
}

func TestStripFrameBlockingHeaders_HandlesMultipleCSPHeaders(t *testing.T) {
	// CSP can be set multiple times; browsers intersect them. Each value
	// must be scrubbed independently.
	resp := &http.Response{Header: http.Header{}}
	resp.Header.Add("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'")
	resp.Header.Add("Content-Security-Policy", "frame-ancestors 'none'") // all-empty after strip
	resp.Header.Add("Content-Security-Policy", "script-src 'self'; frame-ancestors 'self'")

	if err := stripFrameBlockingHeaders(resp); err != nil {
		t.Fatalf("strip: %v", err)
	}
	vals := resp.Header.Values("Content-Security-Policy")
	// Want exactly two values left: the first (frame-ancestors stripped)
	// and the third (frame-ancestors stripped). The all-empty second
	// header is dropped during reassembly.
	if len(vals) != 2 {
		t.Fatalf("expected 2 CSP values after scrub, got %d: %v", len(vals), vals)
	}
	for _, v := range vals {
		if strings.Contains(strings.ToLower(v), "frame-ancestors") {
			t.Errorf("frame-ancestors leaked: %q", v)
		}
	}
}

func TestRemoveFrameAncestorsDirective_PreservesOrdering(t *testing.T) {
	in := "default-src 'self'; img-src data:; frame-ancestors 'none'; script-src 'self'; style-src 'unsafe-inline'"
	got := removeFrameAncestorsDirective(in)
	want := "default-src 'self'; img-src data:; script-src 'self'; style-src 'unsafe-inline'"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestRemoveFrameAncestorsDirective_OnlyDirective(t *testing.T) {
	if got := removeFrameAncestorsDirective("frame-ancestors 'none'"); got != "" {
		t.Errorf("expected empty, got %q", got)
	}
}

func TestRemoveFrameAncestorsDirective_HandlesEmptyAndExtraSemicolons(t *testing.T) {
	// Trailing semicolons + double semicolons are tolerated by browsers;
	// our split should drop empty fragments cleanly.
	in := "default-src 'self';; frame-ancestors 'none'; ;script-src 'self';"
	got := removeFrameAncestorsDirective(in)
	want := "default-src 'self'; script-src 'self'"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestRemoveFrameAncestorsDirective_DoesNotMatchSubstring(t *testing.T) {
	// The directive-name comparison is whole-word case-insensitive — a
	// hypothetical "frame-ancestors-policy" directive must NOT match.
	in := "default-src 'self'; frame-ancestors-policy 'block'; script-src 'self'"
	got := removeFrameAncestorsDirective(in)
	if !strings.Contains(got, "frame-ancestors-policy") {
		t.Errorf("over-matched a substring directive; got %q", got)
	}
}

// --- preview proxy integration tests (root-mounted, ARD-0033) ---------------

// newPreviewProxy builds an httptest.Server wrapping the root-mounted preview
// reverse proxy for the given upstream URL. The handler is what runs on the
// dedicated preview origin in production (a separate http.Server in main.go).
func newPreviewProxy(t *testing.T, previewURL string) *httptest.Server {
	t.Helper()
	h, err := newPreviewProxyHandler(previewURL)
	if err != nil {
		t.Fatalf("newPreviewProxyHandler(%q): %v", previewURL, err)
	}
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return srv
}

func TestPreviewProxy_EmptyURLErrors(t *testing.T) {
	// main.go only starts the preview listener when PreviewURL is non-empty;
	// the handler constructor enforces that contract.
	if _, err := newPreviewProxyHandler(""); err == nil {
		t.Error("expected error for empty preview URL, got nil")
	}
	if _, err := newPreviewProxyHandler("   "); err == nil {
		t.Error("expected error for whitespace-only preview URL, got nil")
	}
}

func TestPreviewProxy_ProxiesToUpstream(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "Hello from upstream")
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status=%d want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "Hello from upstream" {
		t.Errorf("body=%q want %q", string(body), "Hello from upstream")
	}
}

func TestPreviewProxy_StripsFrameOptionsEndToEnd(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; frame-ancestors 'none'")
		_, _ = io.WriteString(w, "ok")
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()

	if got := resp.Header.Get("X-Frame-Options"); got != "" {
		t.Errorf("X-Frame-Options not stripped: %q", got)
	}
	csp := resp.Header.Get("Content-Security-Policy")
	if strings.Contains(strings.ToLower(csp), "frame-ancestors") {
		t.Errorf("frame-ancestors not stripped: %q", csp)
	}
	if !strings.Contains(csp, "default-src 'self'") {
		t.Errorf("default-src dropped from CSP: %q", csp)
	}
}

func TestPreviewProxy_ServesNavScript(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("upstream should not be hit for the nav-script path")
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/__boring_nav.js")
	if err != nil {
		t.Fatalf("GET nav script: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status=%d want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("content-type=%q want javascript", ct)
	}
	body, _ := io.ReadAll(resp.Body)
	// The script identifies itself with the postMessage source marker and
	// guards against nested sub-iframes reporting.
	if !strings.Contains(string(body), "boring-preview") {
		t.Errorf("nav script missing source marker; got %q", string(body))
	}
	if !strings.Contains(string(body), "window.top") {
		t.Errorf("nav script missing top-frame guard; got %q", string(body))
	}
}

func TestPreviewProxy_InjectsNavScriptIntoHTML(t *testing.T) {
	const html = "<!doctype html><html><head><title>x</title></head><body>hi</body></html>"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, html)
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	// Injected, and placed immediately before </head>.
	if !strings.Contains(string(body), `<script src="/__boring_nav.js"></script></head>`) {
		t.Errorf("nav script not injected before </head>; got %q", string(body))
	}
	// Content-Length must reflect the grown body or the client truncates/hangs.
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		if n, _ := strconv.Atoi(cl); n != len(body) {
			t.Errorf("Content-Length=%s but body is %d bytes", cl, len(body))
		}
	}
}

func TestPreviewProxy_DoesNotInjectIntoNonHTML(t *testing.T) {
	const css = "body{color:red}"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/css")
		_, _ = io.WriteString(w, css)
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/theme.css")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if string(body) != css {
		t.Errorf("non-HTML body was altered: got %q want %q", string(body), css)
	}
}

// TestPreviewProxy_InjectsIntoGzippedUpstream proves the Accept-Encoding strip
// works end-to-end: we delete the client's Accept-Encoding so the Go transport
// takes over (re-adds gzip + transparently decompresses), leaving an identity
// body at ModifyResponse time that we can inject into — even when the upstream
// gzips its response.
func TestPreviewProxy_InjectsIntoGzippedUpstream(t *testing.T) {
	const html = "<!doctype html><head></head><body>hi</body>"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			w.Header().Set("Content-Encoding", "gzip")
			gz := gzip.NewWriter(w)
			_, _ = gz.Write([]byte(html))
			_ = gz.Close()
			return
		}
		_, _ = io.WriteString(w, html)
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "/__boring_nav.js") {
		t.Errorf("nav script not injected into transparently-decompressed gzip upstream; got %q", string(body))
	}
}

func TestPreviewProxy_502OnUpstreamUnreachable(t *testing.T) {
	// Bind + immediately close a socket to grab a port nothing is listening
	// on. Using port 1 (often unbound) is unreliable on macOS — this is
	// deterministic.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	deadAddr := ln.Addr().String()
	ln.Close() // port is now free; subsequent connects fail with ECONNREFUSED

	proxy := newPreviewProxy(t, "http://"+deadAddr)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Errorf("status=%d want 502", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "preview backend unreachable") {
		t.Errorf("body=%q want containing %q", string(body), "preview backend unreachable")
	}
}

// TestPreviewProxy_PassesPathAndQueryThrough is the crux of ARD-0033: because
// the proxy is mounted at root (no prefix to strip), an inbound root-absolute
// path like /cdn/shop/assets/theme.css?v=1 reaches the upstream verbatim. This
// is exactly what lets Shopify's root-absolute asset URLs resolve.
func TestPreviewProxy_PassesPathAndQueryThrough(t *testing.T) {
	type seen struct {
		path string
		raw  string
	}
	got := make(chan seen, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- seen{path: r.URL.Path, raw: r.URL.RawQuery}
		_, _ = io.WriteString(w, "ok")
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/cdn/shop/t/144/assets/theme.css?v=12345&width=32")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()

	select {
	case s := <-got:
		if s.path != "/cdn/shop/t/144/assets/theme.css" {
			t.Errorf("upstream saw path %q want %q", s.path, "/cdn/shop/t/144/assets/theme.css")
		}
		if s.raw != "v=12345&width=32" {
			t.Errorf("upstream saw query %q want %q", s.raw, "v=12345&width=32")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream never received request")
	}
}

func TestPreviewProxy_RootPathPassesThrough(t *testing.T) {
	gotPath := make(chan string, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath <- r.URL.Path
		_, _ = io.WriteString(w, "ok")
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()

	select {
	case p := <-gotPath:
		if p != "/" {
			t.Errorf("upstream saw path %q want %q", p, "/")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream never received request")
	}
}

func TestPreviewProxy_HostHeaderRewritten(t *testing.T) {
	// Upstream observes its own Host (target.Host), not the proxy's Host.
	// Real-world relevance: Shopify storefronts vhost-route on Host.
	gotHost := make(chan string, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost <- r.Host
		_, _ = io.WriteString(w, "ok")
	}))
	defer upstream.Close()

	// Compute upstream's host:port for comparison.
	u, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatalf("parse upstream URL: %v", err)
	}
	wantHost := u.Host

	proxy := newPreviewProxy(t, upstream.URL)
	resp, err := http.Get(proxy.URL + "/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()

	select {
	case h := <-gotHost:
		if h != wantHost {
			t.Errorf("upstream saw Host=%q want %q", h, wantHost)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream never received request")
	}
}

// TestPreviewProxy_WebSocketUpgrade verifies the HTTP-layer Upgrade handshake
// is forwarded end-to-end through the reverse proxy. We hijack the connection
// on the upstream side, echo the handshake response, then verify the client
// receives the 101 + the expected headers and can exchange raw bytes.
//
// We don't pull in golang.org/x/net/websocket because the proxy's job is at
// the HTTP Upgrade layer, not the WS framing layer. If the Upgrade handshake
// crosses correctly and bytes flow bidirectionally, httputil.ReverseProxy is
// doing its job — the upstream's actual WS framing is the application's
// concern, not ours. (Shopify theme hot-reload relies on this.)
func TestPreviewProxy_WebSocketUpgrade(t *testing.T) {
	const upstreamGreeting = "upstream-says-hi"
	const clientGreeting = "client-says-hi"

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Sanity-check that the proxy forwarded the upgrade headers.
		if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			t.Errorf("upstream missing Upgrade: websocket header; got %q", r.Header.Get("Upgrade"))
		}
		if !strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
			t.Errorf("upstream missing Connection: upgrade header; got %q", r.Header.Get("Connection"))
		}

		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Errorf("upstream ResponseWriter doesn't support Hijacker")
			http.Error(w, "no hijack", http.StatusInternalServerError)
			return
		}
		conn, bufrw, err := hj.Hijack()
		if err != nil {
			t.Errorf("upstream hijack: %v", err)
			return
		}
		defer conn.Close()

		// Send a 101 Switching Protocols handshake. The proxy must
		// pass this back to the client verbatim (including the
		// Upgrade and Connection headers).
		_, _ = bufrw.WriteString("HTTP/1.1 101 Switching Protocols\r\n")
		_, _ = bufrw.WriteString("Upgrade: websocket\r\n")
		_, _ = bufrw.WriteString("Connection: Upgrade\r\n")
		_, _ = bufrw.WriteString("Sec-WebSocket-Accept: dummy-accept-value\r\n")
		_, _ = bufrw.WriteString("\r\n")
		_ = bufrw.Flush()

		// Read the client's greeting (raw bytes, no WS framing).
		got := make([]byte, len(clientGreeting))
		if _, err := io.ReadFull(bufrw, got); err != nil {
			t.Errorf("upstream read client: %v", err)
			return
		}
		if string(got) != clientGreeting {
			t.Errorf("upstream got client bytes %q want %q", string(got), clientGreeting)
		}

		// Echo a greeting back.
		_, _ = bufrw.WriteString(upstreamGreeting)
		_ = bufrw.Flush()
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)

	// Dial the proxy directly (we need a raw TCP connection so we can drive
	// the Upgrade handshake by hand — http.Client can't do this cleanly).
	proxyURL, err := url.Parse(proxy.URL)
	if err != nil {
		t.Fatalf("parse proxy URL: %v", err)
	}
	conn, err := net.DialTimeout("tcp", proxyURL.Host, 3*time.Second)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	// Send a minimally-valid WebSocket Upgrade request (root-mounted path).
	req := strings.Join([]string{
		"GET /ws HTTP/1.1",
		"Host: " + proxyURL.Host,
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Version: 13",
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
		"", "",
	}, "\r\n")
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatalf("write upgrade req: %v", err)
	}

	// Read the proxy's response — must be 101 Switching Protocols.
	bufr := bufio.NewReader(conn)
	resp, err := http.ReadResponse(bufr, nil)
	if err != nil {
		t.Fatalf("read upgrade resp: %v", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("status=%d want 101 Switching Protocols", resp.StatusCode)
	}
	if !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") {
		t.Errorf("client missing Upgrade: websocket; got %q", resp.Header.Get("Upgrade"))
	}
	if !strings.Contains(strings.ToLower(resp.Header.Get("Connection")), "upgrade") {
		t.Errorf("client missing Connection: upgrade; got %q", resp.Header.Get("Connection"))
	}

	// Post-handshake: send our greeting, expect the upstream's echo.
	if _, err := conn.Write([]byte(clientGreeting)); err != nil {
		t.Fatalf("write client greeting: %v", err)
	}
	got := make([]byte, len(upstreamGreeting))
	if _, err := io.ReadFull(bufr, got); err != nil {
		t.Fatalf("read upstream greeting: %v", err)
	}
	if string(got) != upstreamGreeting {
		t.Errorf("client got %q want %q", string(got), upstreamGreeting)
	}
}

// TestPreviewProxy_RespectsClientCancel — a slow upstream + cancelled client
// must abort the in-flight request rather than blocking forever. Race-detector
// loves this kind of test.
func TestPreviewProxy_RespectsClientCancel(t *testing.T) {
	upstreamDone := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
		close(upstreamDone)
	}))
	defer upstream.Close()

	proxy := newPreviewProxy(t, upstream.URL)
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, proxy.URL+"/", nil)
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()
	_, err := http.DefaultClient.Do(req)
	if err == nil {
		t.Error("expected client cancel error, got nil")
	}

	select {
	case <-upstreamDone:
	case <-time.After(2 * time.Second):
		t.Error("upstream never observed cancellation")
	}
}
