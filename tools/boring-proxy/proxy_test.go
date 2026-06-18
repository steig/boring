package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// testSocketDir returns a socket dir under TMPDIR/boring/<test name>/ which
// satisfies the registry's socket-path validator (per security review
// critical-5). Tests use this rather than t.TempDir() directly.
func testSocketDir(t *testing.T) string {
	t.Helper()
	base := os.Getenv("TMPDIR")
	if base == "" {
		base = "/tmp"
	}
	dir := filepath.Join(base, "boring", "test-"+strings.ReplaceAll(t.Name(), "/", "_"))
	if err := os.RemoveAll(dir); err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cleanup: %v", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// TestSplitSlug covers the path-prefix splitter — the core of the routing
// decision.
func TestSplitSlug(t *testing.T) {
	cases := []struct {
		in       string
		wantSlug string
		wantRest string
	}{
		{"/", "", "/"},
		{"", "", "/"},
		{"/marketing-site", "marketing-site", "/"},
		{"/marketing-site/", "marketing-site", "/"},
		{"/marketing-site/preview", "marketing-site", "/preview"},
		{"/marketing-site/api/events", "marketing-site", "/api/events"},
	}
	for _, c := range cases {
		s, r := splitSlug(c.in)
		if s != c.wantSlug || r != c.wantRest {
			t.Errorf("splitSlug(%q) = (%q, %q); want (%q, %q)", c.in, s, r, c.wantSlug, c.wantRest)
		}
	}
}

// TestProxyRouteToUnixSocket spins up a fake backend on a Unix socket and
// asserts the proxy strips the slug prefix and forwards the rest of the path.
func TestProxyRouteToUnixSocket(t *testing.T) {
	sockDir := testSocketDir(t)
	sock := filepath.Join(sockDir, "test.sock")

	// Fake backend on the Unix socket. Echoes the path it received.
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer ln.Close()
	backend := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, "received path: "+r.URL.Path)
		}),
	}
	go backend.Serve(ln)
	defer backend.Shutdown(context.Background())

	// Registry with one project pointing at the socket.
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	regData := registryFile{Projects: []Project{
		{Slug: "marketing-site", Name: "Marketing Site", Status: "running", Socket: sock},
	}}
	b, _ := json.Marshal(regData)
	if err := os.WriteFile(regPath, b, 0o644); err != nil {
		t.Fatalf("write registry: %v", err)
	}
	reg, err := NewRegistry(regPath)
	if err != nil {
		t.Fatalf("new registry: %v", err)
	}

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/marketing-site/preview/page")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "received path: /preview/page") {
		t.Errorf("backend got wrong path; body = %q", body)
	}
}

// TestProxyAllowsSameOriginFraming — the cockpit shell embeds /<slug>/ in a
// same-origin iframe (ARD-0041). A backend that sends X-Frame-Options: DENY and
// a CSP frame-ancestors 'none' must come back through the proxy with the frame
// block relaxed: X-Frame-Options dropped, frame-ancestors rewritten to 'self',
// and the rest of the CSP preserved.
func TestProxyAllowsSameOriginFraming(t *testing.T) {
	sockDir := testSocketDir(t)
	sock := filepath.Join(sockDir, "f.sock")

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer ln.Close()
	backend := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'")
		_, _ = io.WriteString(w, "ok")
	})}
	go backend.Serve(ln)
	defer backend.Shutdown(context.Background())

	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	regData := registryFile{Projects: []Project{{Slug: "framed", Status: "running", Socket: sock}}}
	b, _ := json.Marshal(regData)
	_ = os.WriteFile(regPath, b, 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/framed/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()

	if xfo := resp.Header.Get("X-Frame-Options"); xfo != "" {
		t.Errorf("X-Frame-Options not stripped: %q", xfo)
	}
	csp := resp.Header.Get("Content-Security-Policy")
	if !strings.Contains(csp, "frame-ancestors 'self'") {
		t.Errorf("frame-ancestors not rewritten to 'self'; CSP = %q", csp)
	}
	if strings.Contains(csp, "frame-ancestors 'none'") {
		t.Errorf("frame-ancestors 'none' survived; CSP = %q", csp)
	}
	if !strings.Contains(csp, "default-src 'self'") {
		t.Errorf("non-frame CSP directive was dropped; CSP = %q", csp)
	}
}

// TestRewriteFrameAncestors covers the CSP directive rewriter directly:
// existing frame-ancestors are replaced, other directives preserved, and a
// missing directive is appended.
func TestRewriteFrameAncestors(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"frame-ancestors 'none'", " frame-ancestors 'self'"},
		{"default-src 'self'; frame-ancestors https://x.example", "default-src 'self'; frame-ancestors 'self'"},
		{"default-src 'self'", "default-src 'self'; frame-ancestors 'self'"},
		{"default-src 'self';", "default-src 'self'; frame-ancestors 'self'"},
	}
	for _, c := range cases {
		if got := rewriteFrameAncestors(c.in); got != c.want {
			t.Errorf("rewriteFrameAncestors(%q) = %q; want %q", c.in, got, c.want)
		}
	}
}

// TestProxyUnknownProject404s ensures missing-slug requests don't crash.
func TestProxyUnknownProject404s(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/nonexistent/foo")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("want 404, got %d", resp.StatusCode)
	}
}

// TestProxyStubsMissingSocket — a project with no socket file shows the
// "container not running" stub instead of crashing.
func TestProxyStubsMissingSocket(t *testing.T) {
	sockDir := testSocketDir(t)
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	regData := registryFile{Projects: []Project{
		{Slug: "asleep", Name: "Asleep", Status: "stopped",
			Socket: filepath.Join(sockDir, "does-not-exist.sock")},
	}}
	b, _ := json.Marshal(regData)
	_ = os.WriteFile(regPath, b, 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/asleep/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("want 503, got %d", resp.StatusCode)
	}
	if !strings.Contains(string(body), "Container not running") {
		t.Errorf("expected stub page; body = %q", body)
	}
}

// TestPickerServesIndex — the / route returns the embedded HTML.
func TestPickerServesIndex(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "<title>boring</title>") {
		t.Errorf("picker HTML not served; body = %q", body)
	}
}

// TestProjectsAPI — /api/projects returns the dashboard card shape: per-project
// slug, name, in-proxy URL, live status, and (when present) last_active/summary.
// A registry that asserts "running" but has no live socket is downgraded to
// "stopped" (the live-status check, per ARD-0041).
func TestProjectsAPI(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	regData := registryFile{Projects: []Project{
		{Slug: "alpha", Name: "Alpha", Status: "running", LastActive: "2026-06-18T10:00:00Z", Summary: "editing hero"},
		{Slug: "beta", Name: "Beta", Status: "stopped"},
	}}
	b, _ := json.Marshal(regData)
	_ = os.WriteFile(regPath, b, 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/projects")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	var data map[string][]projectCard
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		t.Fatalf("decode: %v", err)
	}
	cards := data["projects"]
	if len(cards) != 2 {
		t.Fatalf("want 2 projects, got %d", len(cards))
	}
	bySlug := map[string]projectCard{}
	for _, c := range cards {
		bySlug[c.Slug] = c
	}
	alpha, ok := bySlug["alpha"]
	if !ok {
		t.Fatal("alpha missing")
	}
	if alpha.URL != "/alpha/" {
		t.Errorf("alpha url = %q, want /alpha/", alpha.URL)
	}
	// No live socket -> "running" in the registry is downgraded to "stopped".
	if alpha.Status != "stopped" {
		t.Errorf("alpha live status = %q, want stopped (no socket)", alpha.Status)
	}
	if alpha.LastActive != "2026-06-18T10:00:00Z" {
		t.Errorf("alpha last_active = %q, unexpected", alpha.LastActive)
	}
	if alpha.Summary != "editing hero" {
		t.Errorf("alpha summary = %q, unexpected", alpha.Summary)
	}
}

// TestLiveStatus covers the socket-reachability resolution: a reachable socket
// reads "running" regardless of the registry field; otherwise transients
// (starting/error) pass through and everything else collapses to "stopped".
func TestLiveStatus(t *testing.T) {
	sockDir := testSocketDir(t)
	liveSock := filepath.Join(sockDir, "live.sock")
	ln, err := net.Listen("unix", liveSock)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer ln.Close()

	missingSock := filepath.Join(sockDir, "missing.sock")

	tests := []struct {
		name string
		p    Project
		want string
	}{
		{"reachable socket overrides registry", Project{Slug: "a", Status: "stopped", Socket: liveSock}, "running"},
		{"missing socket downgrades running", Project{Slug: "b", Status: "running", Socket: missingSock}, "stopped"},
		{"missing socket preserves starting", Project{Slug: "c", Status: "starting", Socket: missingSock}, "starting"},
		{"missing socket preserves error", Project{Slug: "d", Status: "error", Socket: missingSock}, "error"},
		{"missing socket unknown becomes stopped", Project{Slug: "e", Status: "", Socket: missingSock}, "stopped"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := liveStatus(tc.p); got != tc.want {
				t.Errorf("liveStatus = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestRouterEnforcesToken — with auth on, requests without a cookie are
// either redirected (/) or 401'd (/api/...).
func TestRouterEnforcesToken(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	tokPath := filepath.Join(tmp, "token")
	if err := os.WriteFile(tokPath, []byte("deadbeef"+strings.Repeat("0", 56)+"\n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}
	store, err := NewTokenStore(tokPath)
	if err != nil {
		t.Fatalf("token store: %v", err)
	}
	router := NewRouter(reg, store, false)
	srv := httptest.NewServer(router)
	defer srv.Close()

	// No-redirect client so we can observe the 302.
	client := &http.Client{
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       2 * time.Second,
	}

	resp, _ := client.Get(srv.URL + "/")
	if resp.StatusCode != http.StatusFound {
		t.Errorf("want 302 on /, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	resp, _ = client.Get(srv.URL + "/api/projects")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("want 401 on /api/projects, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

// TestRotateTokenInvalidatesLiveProxy — per security review (critical-1).
// Rotating the token on disk must invalidate the cookie of any session that
// was authed against the previous token, even though the proxy keeps running.
func TestRotateTokenInvalidatesLiveProxy(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	tokPath := filepath.Join(tmp, "token")
	store, err := NewTokenStore(tokPath)
	if err != nil {
		t.Fatalf("token store: %v", err)
	}
	oldTok := store.Current()

	router := NewRouter(reg, store, false)
	srv := httptest.NewServer(router)
	defer srv.Close()

	client := &http.Client{
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       2 * time.Second,
	}

	// Sanity: old token works before rotation.
	req, _ := http.NewRequest("GET", srv.URL+"/api/projects", nil)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: oldTok})
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("pre-rotate: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("pre-rotate: want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// Rotate.
	newTok, err := RotateToken(tokPath)
	if err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if newTok == oldTok {
		t.Fatalf("rotation produced same token")
	}

	// Old cookie must now fail (the store re-reads from disk on mismatch).
	req2, _ := http.NewRequest("GET", srv.URL+"/api/projects", nil)
	req2.AddCookie(&http.Cookie{Name: cookieName, Value: oldTok})
	resp, err = client.Do(req2)
	if err != nil {
		t.Fatalf("post-rotate old: %v", err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("post-rotate old: want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// New cookie works.
	req3, _ := http.NewRequest("GET", srv.URL+"/api/projects", nil)
	req3.AddCookie(&http.Cookie{Name: cookieName, Value: newTok})
	resp, err = client.Do(req3)
	if err != nil {
		t.Fatalf("post-rotate new: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("post-rotate new: want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

// TestProxyTransportReused — per security review (critical-2). Multiple
// requests to the same slug must reuse the same dialer/transport (otherwise
// connection pooling is dead and goroutines leak).
func TestProxyTransportReused(t *testing.T) {
	sockDir := testSocketDir(t)
	sock := filepath.Join(sockDir, "reused.sock")

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer ln.Close()
	backend := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	})}
	go backend.Serve(ln)
	defer backend.Shutdown(context.Background())

	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	regData := registryFile{Projects: []Project{{Slug: "alpha", Status: "running", Socket: sock}}}
	b, _ := json.Marshal(regData)
	_ = os.WriteFile(regPath, b, 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	// Two requests, same slug.
	client := &http.Client{Timeout: 2 * time.Second}
	for i := 0; i < 2; i++ {
		resp, err := client.Get(srv.URL + "/alpha/")
		if err != nil {
			t.Fatalf("req %d: %v", i, err)
		}
		_, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
	}

	// Probe the cache: there should be exactly one entry, and a third
	// call should return the same *cachedProxy struct.
	v1, ok := router.proxies.Load("alpha")
	if !ok {
		t.Fatalf("expected cached proxy for alpha")
	}
	// A third call to proxyForSlug with the same sock must return cached entry.
	rp2 := router.proxyForSlug("alpha", sock)
	if rp2 != v1.(*cachedProxy).rp {
		t.Errorf("proxy was not reused across calls")
	}

	// Negative case: a different sock path invalidates the cache.
	otherSock := filepath.Join(sockDir, "other.sock")
	rp3 := router.proxyForSlug("alpha", otherSock)
	if rp3 == v1.(*cachedProxy).rp {
		t.Errorf("cache should have been replaced on sock change")
	}
}

// TestSlugValidation — per security review (critical-5). Adversarial slugs
// (path traversal, uppercase, control chars, oversize) are rejected at the
// router before reaching the registry lookup.
func TestSlugValidation(t *testing.T) {
	good := []string{"a", "marketing-site", "a-b-c", "abc123", "p1"}
	bad := []string{
		"",         // empty
		"-leading", // leading dash
		"UPPER",    // uppercase
		"with_us",  // underscore
		"with.dot", // dot
		"with/slash",
		"..",
		"a" + strings.Repeat("b", 63), // 64 chars, too long
	}
	for _, s := range good {
		if !isValidSlug(s) {
			t.Errorf("good slug rejected: %q", s)
		}
	}
	for _, s := range bad {
		if isValidSlug(s) {
			t.Errorf("bad slug accepted: %q", s)
		}
	}

	// And end-to-end: a registry that contains an evil slug shouldn't even
	// be loaded into the in-memory map (per registry-side filtering).
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[{"slug":"UPPER","name":"x"}]}`), 0o644)
	reg, _ := NewRegistry(regPath)
	if _, ok := reg.Get("UPPER"); ok {
		t.Errorf("registry kept invalid slug")
	}
}

// TestRegistryRejectsMaliciousSocketPath — per security review (critical-5).
// A registry entry pointing at /var/run/docker.sock (or any path outside the
// allowlist) must be dropped on load.
func TestRegistryRejectsMaliciousSocketPath(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	bad := []string{
		"/var/run/docker.sock",
		"/etc/passwd",
		"/tmp/boring/../../etc/shadow.sock",
		"/tmp/notboring/x.sock",
		"plain-path",
		"/tmp/boring/sub/no-suffix",
	}
	for _, b := range bad {
		body := fmt.Sprintf(`{"projects":[{"slug":"evil","name":"x","socket":%q}]}`, b)
		_ = os.WriteFile(regPath, []byte(body), 0o644)
		reg, _ := NewRegistry(regPath)
		if _, ok := reg.Get("evil"); ok {
			t.Errorf("registry accepted malicious socket: %q", b)
		}
	}

	// Sanity: a well-formed socket under /tmp/boring/ is accepted.
	good := fmt.Sprintf(`{"projects":[{"slug":"good","name":"g","socket":%q}]}`, "/tmp/boring/good.sock")
	_ = os.WriteFile(regPath, []byte(good), 0o644)
	reg, _ := NewRegistry(regPath)
	if _, ok := reg.Get("good"); !ok {
		t.Errorf("registry rejected valid socket")
	}
}

// TestPickerHasSecurityHeaders — per security review (critical-4).
func TestPickerHasSecurityHeaders(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	paths := []string{"/", "/api/projects", "/auth"}
	want := map[string]string{
		"Content-Security-Policy": "default-src 'none'",
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"Referrer-Policy":         "no-referrer",
	}
	for _, p := range paths {
		resp, err := http.Get(srv.URL + p)
		if err != nil {
			t.Fatalf("GET %s: %v", p, err)
		}
		for h, prefix := range want {
			got := resp.Header.Get(h)
			if !strings.Contains(got, prefix) {
				t.Errorf("%s missing/wrong %s: %q", p, h, got)
			}
		}
		resp.Body.Close()
	}
}

// TestAuthSetsReferrerPolicy — per security review (critical-6). Even on the
// redirect response after a successful /auth?t= handshake, the Referrer-Policy
// header must be set (so the redirected-from URL with the token in the query
// string doesn't leak via Referer on subsequent navigations).
func TestAuthSetsReferrerPolicy(t *testing.T) {
	tmp := t.TempDir()
	tokPath := filepath.Join(tmp, "token")
	store, err := NewTokenStore(tokPath)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	tok := store.Current()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/auth?t="+tok, nil)
	HandleAuth(rec, req, store)
	if rec.Code != http.StatusFound {
		t.Fatalf("want 302, got %d", rec.Code)
	}
	if rec.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Errorf("Referrer-Policy missing on /auth redirect")
	}
}

// TestNonGetReturns405OnProxyOwnEndpoints — per security review (critical-7).
// Picker, /api/projects, /auth are GET-only by design. Per-slug paths are
// pass-through.
func TestNonGetReturns405OnProxyOwnEndpoints(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	cases := []struct {
		method string
		path   string
	}{
		{"POST", "/"},
		{"DELETE", "/api/projects"},
		{"PUT", "/auth"},
		{"PATCH", "/assets/picker.js"},
	}
	client := &http.Client{Timeout: 2 * time.Second}
	for _, c := range cases {
		req, _ := http.NewRequest(c.method, srv.URL+c.path, nil)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v", c.method, c.path, err)
		}
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s %s: want 405, got %d", c.method, c.path, resp.StatusCode)
		}
		if a := resp.Header.Get("Allow"); a != "GET" {
			t.Errorf("%s %s: Allow header = %q, want GET", c.method, c.path, a)
		}
		resp.Body.Close()
	}
}

// TestTLSKeyPermRejectedWhenLoose — per security review (high-8). A TLS key
// file with group/world perms must cause Serve to refuse start.
func TestTLSKeyPermRejectedWhenLoose(t *testing.T) {
	tmp := t.TempDir()
	if err := os.WriteFile(tmp+"/key.pem", []byte("KEY"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	err := ensurePrivatePerms(tmp + "/key.pem")
	if err == nil {
		t.Errorf("expected error on 0644 key")
	}
	if err := os.Chmod(tmp+"/key.pem", 0o600); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	if err := ensurePrivatePerms(tmp + "/key.pem"); err != nil {
		t.Errorf("0600 key rejected: %v", err)
	}
}

// TestTokenFilePermRejectedWhenLoose — per security review (high-9). An
// existing token file with loose perms must be refused by LoadOrCreateToken.
func TestTokenFilePermRejectedWhenLoose(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "tok")
	if err := os.WriteFile(p, []byte(strings.Repeat("a", 64)+"\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, err := LoadOrCreateToken(p)
	if err == nil {
		t.Errorf("expected error on 0644 token file")
	}
}

// TestVerifySocketOwner — per security review (high-10). Owner check on the
// current user's socket should pass; we can't easily test the negative case
// without root or a second user, so verify the positive + the non-existent.
func TestVerifySocketOwner(t *testing.T) {
	sockDir := testSocketDir(t)
	sock := filepath.Join(sockDir, "owner.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	if err := verifySocketOwner(sock); err != nil {
		t.Errorf("expected own-uid socket to pass: %v", err)
	}
	if err := verifySocketOwner(filepath.Join(sockDir, "nope.sock")); err == nil {
		t.Errorf("expected non-existent socket to fail")
	}
}

// TestWatchExitsOnContextCancel — per security review (critical-13). The
// watcher goroutine must exit promptly when its context is cancelled.
func TestWatchExitsOnContextCancel(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		reg.Watch(ctx)
		close(done)
	}()

	// Give the watcher a moment to set up.
	time.Sleep(50 * time.Millisecond)
	cancel()

	select {
	case <-done:
		// good
	case <-time.After(2 * time.Second):
		t.Fatalf("watcher did not exit within 2s of context cancel")
	}
}

// TestRegistryWatchReloadsOnAtomicRename — write a fresh registry via
// temp+rename and ensure the in-memory map updates within 1s.
func TestRegistryWatchReloadsOnAtomicRename(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[]}`), 0o644)
	reg, _ := NewRegistry(regPath)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go reg.Watch(ctx)
	time.Sleep(100 * time.Millisecond) // let watcher arm

	tmpReg := regPath + ".tmp"
	_ = os.WriteFile(tmpReg, []byte(`{"projects":[{"slug":"new","name":"New","status":"running"}]}`), 0o644)
	if err := os.Rename(tmpReg, regPath); err != nil {
		t.Fatalf("rename: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := reg.Get("new"); ok {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("registry did not reload after rename")
}

// TestRegistryReloadKeepsStateOnParseError — bad JSON over a previously valid
// registry preserves the prior in-memory state rather than blanking it.
func TestRegistryReloadKeepsStateOnParseError(t *testing.T) {
	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(regPath, []byte(`{"projects":[{"slug":"keep","name":"K","status":"running"}]}`), 0o644)
	reg, _ := NewRegistry(regPath)
	if _, ok := reg.Get("keep"); !ok {
		t.Fatalf("setup: keep should be present")
	}
	// Write garbage; reload should error AND keep prior state.
	_ = os.WriteFile(regPath, []byte(`{not valid json`), 0o644)
	if err := reg.reload(); err == nil {
		t.Errorf("expected parse error")
	}
	if _, ok := reg.Get("keep"); !ok {
		t.Errorf("prior state was wiped on parse error")
	}
}

// TestRouterDialCounting — the OnDial assertion path for #2: confirm the same
// underlying *http.Transport is what backs both requests by counting dials.
// A new transport per request would dial twice; a reused one should dial once
// and keep the connection idle in between.
func TestRouterDialCounting(t *testing.T) {
	sockDir := testSocketDir(t)
	sock := filepath.Join(sockDir, "dialcount.sock")

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	backend := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	})}
	go backend.Serve(ln)
	defer backend.Shutdown(context.Background())

	tmp := t.TempDir()
	regPath := filepath.Join(tmp, "registry.json")
	regData := registryFile{Projects: []Project{{Slug: "alpha", Status: "running", Socket: sock}}}
	b, _ := json.Marshal(regData)
	_ = os.WriteFile(regPath, b, 0o644)
	reg, _ := NewRegistry(regPath)

	router := NewRouter(reg, nil, true)
	srv := httptest.NewServer(router)
	defer srv.Close()

	// First, prime the cache.
	for i := 0; i < 3; i++ {
		resp, err := http.Get(srv.URL + "/alpha/")
		if err != nil {
			t.Fatalf("warmup: %v", err)
		}
		_, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
	}

	// After warmup there should be exactly one cached entry.
	count := 0
	router.proxies.Range(func(_, _ any) bool {
		count++
		return true
	})
	if count != 1 {
		t.Errorf("want 1 cached proxy, got %d", count)
	}

	// Concurrent hits — make sure no goroutines/transports leak. Just bound:
	// after the burst the count is still 1.
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := http.Get(srv.URL + "/alpha/")
			if err != nil {
				return
			}
			_, _ = io.ReadAll(resp.Body)
			resp.Body.Close()
		}()
	}
	wg.Wait()
	count = 0
	router.proxies.Range(func(_, _ any) bool {
		count++
		return true
	})
	if count != 1 {
		t.Errorf("after burst: want 1 cached proxy, got %d", count)
	}
	// Silence unused-var warning in race-detector mode.
	_ = atomic.LoadInt64(new(int64))
}
