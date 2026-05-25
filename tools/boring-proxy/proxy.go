// proxy.go — reverse-proxy core: TLS termination, path-prefix routing.
// For path /<slug>/..., forward to the project's Unix socket. For /, /api/projects,
// /assets/*, /auth — serve the picker. Anything else 404s.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// slugRe matches valid project slugs (DNS-label-ish). Anchored, lowercase,
// 1-63 chars. Per security review (critical-5).
var slugRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

func isValidSlug(s string) bool { return slugRe.MatchString(s) }

// ServeConfig is the runtime config for the proxy in serve mode.
type ServeConfig struct {
	Insecure bool
	Port     int
	Bind     string
	NoAuth   bool
}

// Serve binds the listener, wires the registry watcher and the request handler,
// and blocks until SIGINT/SIGTERM. TLS terminates on the listener; routing
// dispatches into the picker or per-project reverse proxy.
func Serve(cfg ServeConfig) error {
	dataDir, err := DataDir()
	if err != nil {
		return fmt.Errorf("resolve data dir: %w", err)
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}

	reg, err := NewRegistry(filepath.Join(dataDir, "registry.json"))
	if err != nil {
		return fmt.Errorf("load registry: %w", err)
	}

	// Per security review (critical-13): propagate the SIGINT-derived context
	// into the watcher so the goroutine exits on shutdown.
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go reg.Watch(ctx)

	var store *TokenStore
	if !cfg.NoAuth {
		s, err := NewTokenStore(filepath.Join(dataDir, "proxy", "token"))
		if err != nil {
			return fmt.Errorf("load token: %w", err)
		}
		store = s
		// Per security review (critical-1): watch the token file so rotation
		// invalidates live sessions without a proxy restart.
		go store.Watch(ctx)
	}

	router := NewRouter(reg, store, cfg.NoAuth)
	// Invalidate cached reverse proxies when the registry changes (the slug
	// may now point at a different socket).
	reg.SetReloadHook(router.InvalidateProxyCache)

	mux := http.NewServeMux()
	mux.Handle("/", router)

	addr := fmt.Sprintf("%s:%d", cfg.Bind, cfg.Port)
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		// Long timeouts: chat event-streams + websockets need to stay open.
		// TODO(boring-ui): tune per-route once SSE/WS routing is in.
		ReadTimeout:  0,
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		<-ctx.Done()
		log.Printf("shutting down on signal")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	if cfg.Insecure {
		log.Printf("listening on http://%s (insecure / dev mode)", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("listen: %w", err)
		}
		return nil
	}

	certPath := filepath.Join(dataDir, "proxy", "tls", "boring.local.pem")
	keyPath := filepath.Join(dataDir, "proxy", "tls", "boring.local-key.pem")
	if _, err := os.Stat(certPath); err != nil {
		return fmt.Errorf("TLS cert not found at %s — run `boring proxy install` first (or use --insecure for dev)", certPath)
	}
	// Per security review (high-8): refuse to start if the private key has
	// loose perms.
	if err := ensurePrivatePerms(keyPath); err != nil {
		return fmt.Errorf("TLS key perms: %w", err)
	}

	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	srv.TLSConfig = tlsCfg

	log.Printf("listening on https://%s", addr)
	if err := srv.ListenAndServeTLS(certPath, keyPath); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("listen TLS: %w", err)
	}
	return nil
}

// Router dispatches incoming requests by path. Picker requests are handled by
// the picker handler; per-project requests are forwarded over Unix sockets.
// One *httputil.ReverseProxy is cached per slug so the underlying transport
// (and its idle-connection pool) is reused across requests — per security
// review (critical-2).
type Router struct {
	Registry *Registry
	Store    *TokenStore
	NoAuth   bool

	proxies sync.Map // slug -> *cachedProxy
}

// cachedProxy keeps the constructed reverse proxy plus the socket path it was
// built for, so we can detect when the registry remaps the slug to a new socket.
type cachedProxy struct {
	sock string
	rp   *httputil.ReverseProxy
}

// NewRouter constructs a Router with the given dependencies.
func NewRouter(reg *Registry, store *TokenStore, noAuth bool) *Router {
	return &Router{Registry: reg, Store: store, NoAuth: noAuth}
}

// InvalidateProxyCache drops all cached reverse proxies. Called from the
// registry reload hook so a socket-path change is honored on the next request.
func (r *Router) InvalidateProxyCache() {
	r.proxies.Range(func(k, _ any) bool {
		r.proxies.Delete(k)
		return true
	})
}

func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	// /auth is the bootstrap handshake — sets the cookie from a URL token.
	// Must be reachable without an existing cookie.
	if req.URL.Path == "/auth" {
		if req.Method != http.MethodGet {
			methodNotAllowed(w)
			return
		}
		HandleAuth(w, req, r.Store)
		return
	}

	// Token gate for everything else (when auth is enabled).
	if !r.NoAuth {
		if !ValidateRequest(req, r.Store) {
			// Picker pages get redirected to /auth so they can present a friendly
			// "click to authenticate" page; API/proxy routes get a 401.
			setSecurityHeaders(w)
			if req.URL.Path == "/" || strings.HasPrefix(req.URL.Path, "/assets/") {
				http.Redirect(w, req, "/auth", http.StatusFound)
				return
			}
			http.Error(w, "unauthorized — visit /auth?t=<token> first", http.StatusUnauthorized)
			return
		}
	}

	// Picker routes — GET only.
	switch {
	case req.URL.Path == "/" || req.URL.Path == "/index.html":
		if req.Method != http.MethodGet {
			methodNotAllowed(w)
			return
		}
		setSecurityHeaders(w)
		ServePickerIndex(w, req)
		return
	case strings.HasPrefix(req.URL.Path, "/assets/"):
		if req.Method != http.MethodGet {
			methodNotAllowed(w)
			return
		}
		setSecurityHeaders(w)
		ServePickerAsset(w, req)
		return
	case req.URL.Path == "/api/projects":
		if req.Method != http.MethodGet {
			methodNotAllowed(w)
			return
		}
		setSecurityHeaders(w)
		ServeProjectsAPI(w, req, r.Registry)
		return
	}

	// Per-project: /<slug>/... -> per-project Unix socket.
	slug, _ := splitSlug(req.URL.Path)
	if slug == "" {
		setSecurityHeaders(w)
		http.NotFound(w, req)
		return
	}
	// Per security review (critical-5): reject malformed slugs before any
	// registry lookup so adversarial path segments can't even reach Get().
	if !isValidSlug(slug) {
		setSecurityHeaders(w)
		http.NotFound(w, req)
		return
	}
	project, ok := r.Registry.Get(slug)
	if !ok {
		setSecurityHeaders(w)
		http.Error(w, fmt.Sprintf("unknown project: %s", slug), http.StatusNotFound)
		return
	}

	r.proxyToProject(w, req, project)
}

// methodNotAllowed writes a 405 with an Allow: GET header and the standard
// security headers. Per security review (critical-7).
func methodNotAllowed(w http.ResponseWriter) {
	setSecurityHeaders(w)
	w.Header().Set("Allow", "GET")
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

// setSecurityHeaders writes the standard set of restrictive headers for any
// proxy-owned response (picker, api, auth, error pages). Backend-proxied
// responses are NOT touched — those are the backend's concern. Per security
// review (critical-4, critical-6).
func setSecurityHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Security-Policy",
		"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "+
			"connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
}

// proxyToProject forwards req to the project's Unix socket. If the socket
// doesn't exist, render a stub "container not yet implemented" page.
func (r *Router) proxyToProject(w http.ResponseWriter, req *http.Request, p Project) {
	sock := p.Socket
	if sock == "" {
		sock = defaultSocketPath(p.Slug)
	}
	if _, err := os.Stat(sock); err != nil {
		setSecurityHeaders(w)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, `<!doctype html><html><body style="font-family:system-ui;padding:2rem">
<h1>Container not running</h1>
<p>Project <code>%s</code> isn't up yet. v0 prototype: the picker will eventually launch it via <code>boring open</code>; for now this is a stub.</p>
<p><a href="/">&larr; Back to picker</a></p>
</body></html>`, p.Slug)
		return
	}
	// Per security review (high-10): refuse to dial a socket we don't own.
	if err := verifySocketOwner(sock); err != nil {
		log.Printf("proxy: refusing socket %s: %v", sock, err)
		setSecurityHeaders(w)
		http.Error(w, "socket owner mismatch", http.StatusForbidden)
		return
	}

	rp := r.proxyForSlug(p.Slug, sock)
	rp.ServeHTTP(w, req)
}

// proxyForSlug returns a cached reverse proxy for the slug, constructing one
// on first request. If the socket path has changed since the cached entry was
// built, a fresh proxy is constructed. Per security review (critical-2): one
// transport per slug, reused across requests for connection pooling and to
// avoid leaking goroutines (transport's idle-conn manager).
func (r *Router) proxyForSlug(slug, sock string) *httputil.ReverseProxy {
	if v, ok := r.proxies.Load(slug); ok {
		cp := v.(*cachedProxy)
		if cp.sock == sock {
			return cp.rp
		}
		r.proxies.Delete(slug)
	}
	rp := buildProxy(slug, sock)
	// LoadOrStore guards against the rare race where two requests for a fresh
	// slug both miss the cache; the loser's transport is discarded (no idle
	// conns yet, so no leak).
	actual, loaded := r.proxies.LoadOrStore(slug, &cachedProxy{sock: sock, rp: rp})
	if loaded {
		return actual.(*cachedProxy).rp
	}
	return rp
}

// buildProxy constructs a fresh ReverseProxy bound to a Unix socket. Rewrite
// strips the /<slug> prefix from the incoming path at request time (rather
// than baking it into the closure) so the cached proxy is reusable across
// requests with different tails. Per security review (critical-2).
func buildProxy(slug, sock string) *httputil.ReverseProxy {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", sock)
		},
		// Streaming-friendly defaults — chat event streams + websockets.
		ResponseHeaderTimeout: 0,
		IdleConnTimeout:       120 * time.Second,
	}
	target, _ := url.Parse("http://unix")
	return &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			_, rest := splitSlug(pr.In.URL.Path)
			pr.Out.URL.Path = rest
			pr.Out.Host = "unix"
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("upstream error (slug=%s): %v", slug, err)
			setSecurityHeaders(w)
			http.Error(w, "upstream backend error", http.StatusBadGateway)
		},
	}
}

// verifySocketOwner confirms the socket's owner uid matches the current
// process. Refuses to dial otherwise. Per security review (high-10).
func verifySocketOwner(sock string) error {
	st, err := os.Lstat(sock)
	if err != nil {
		return fmt.Errorf("lstat: %w", err)
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		// Should never happen on linux/darwin (our targets), but fail closed.
		return fmt.Errorf("stat_t unavailable on this platform")
	}
	if int(sys.Uid) != os.Getuid() {
		return fmt.Errorf("socket uid=%d not owned by current uid=%d", sys.Uid, os.Getuid())
	}
	return nil
}

// splitSlug pulls "/foo/bar/baz" into ("foo", "/bar/baz"). Trailing-slash
// requests like "/foo" return ("foo", "/"). Empty path returns ("", "/").
func splitSlug(path string) (string, string) {
	p := strings.TrimPrefix(path, "/")
	if p == "" {
		return "", "/"
	}
	idx := strings.IndexByte(p, '/')
	if idx < 0 {
		return p, "/"
	}
	return p[:idx], p[idx:]
}

// defaultSocketPath returns the conventional Unix socket path for a project.
// ARD-0021 §6.1 names $XDG_RUNTIME_DIR/boring/<slug>.sock. macOS doesn't set
// XDG_RUNTIME_DIR, so fall back to $TMPDIR.
func defaultSocketPath(slug string) string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "boring", slug+".sock")
	}
	tmp := os.Getenv("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	return filepath.Join(tmp, "boring", slug+".sock")
}
