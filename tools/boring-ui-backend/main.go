// main.go — boring-ui-backend entry point.
//
// Runs in-container as the chat backend for one project. Listens on a Unix
// socket the host-side proxy (ARD-0021) dials into. v0 prototype: mock AI
// events stand in for OpenCode integration until subscription verification
// (ARD-0020) lights up the real harness.
//
// Usage:
//
//	boring-ui-backend --socket /run/boring/marketing-site.sock \
//	                  --slug marketing-site \
//	                  --workdir /workspaces/marketing-site \
//	                  --provider mock|claude
//
// The --provider flag selects how /api/messages turns are run:
//   - mock   : deterministic fixture sequence (default; no AI billing)
//   - claude : spawn the real `claude` CLI; preserves Claude Max subscription
//     billing. Requires `claude` on PATH and ANTHROPIC_API_KEY unset.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func main() {
	var (
		socketPath   = flag.String("socket", "", "Unix socket path to listen on (required)")
		slug         = flag.String("slug", "", "project slug (required)")
		workdir      = flag.String("workdir", "", "project working directory (required)")
		threadsDir   = flag.String("threads-dir", DefaultThreadsDir, "directory for thread JSONL files")
		provider     = flag.String("provider", "mock", "AI provider: mock | claude")
		mock         = flag.Bool("mock", false, "deprecated alias for --provider=mock")
		previewURL   = flag.String("preview-url", "", "absolute UPSTREAM URL to preview (per ARD-0022 §6); empty shows fallback message. The iframe does NOT load this directly — when --preview-port is set, a dedicated-origin reverse proxy on that port forwards to this URL and strips X-Frame-Options + CSP frame-ancestors per ARD-0033, so upstreams with iframe-hostile headers (Shopify, GitHub, most prod sites) render and their root-absolute asset URLs resolve.")
		previewPort  = flag.Int("preview-port", 0, "host TCP port (bound on 127.0.0.1) for the dedicated-origin preview reverse proxy (ARD-0033). Required for the preview iframe to render; with --preview-url set but this unset, the UI shows the fallback message. 0 disables.")
		terminalURL  = flag.String("terminal-url", "", "absolute URL the LEFT-pane terminal iframe loads (e.g. ttyd serving claude); empty renders the SSE chat UI instead. DEPRECATED in favor of --terminal-urls (ARD-0035); kept as a back-compat singular alias — when set with --terminal-urls empty, parsed as a one-tab list named 'default'. Setting both is an error.")
		terminalURLs = flag.String("terminal-urls", "", "comma-separated <name>=<url> pairs, one per agent tab in the LEFT pane (ARD-0035). Examples: --terminal-urls claude=http://127.0.0.1:7681/ — single tab, equivalent to --terminal-url; --terminal-urls claude=http://127.0.0.1:7681/,codex=http://127.0.0.1:8567/ — two tabs, renders a tab strip. Names must be unique slug-shape; URLs are loaded as iframe srcs. Empty → falls back to --terminal-url, then to the SSE chat UI.")
		allowedPaths = flag.String("allowed-paths", "", "comma-separated glob patterns relative to workdir; files modified by the AI outside these patterns are reverted via git after each turn. Empty disables enforcement.")
	)
	flag.Parse()

	if *socketPath == "" || *slug == "" || *workdir == "" {
		fmt.Fprintln(os.Stderr, "usage: boring-ui-backend --socket <path> --slug <name> --workdir <path> [--provider mock|claude] [--preview-url <url>] [--terminal-urls <name>=<url>,...] [--allowed-paths <globs>]")
		os.Exit(2)
	}

	// ARD-0035 §1: --terminal-urls is the multi-agent shape; --terminal-url
	// is the singular back-compat alias. They are mutually exclusive — setting
	// both invites the question "which one wins" and there's no good answer.
	if *terminalURL != "" && *terminalURLs != "" {
		fmt.Fprintln(os.Stderr, "boring-ui-backend: --terminal-url and --terminal-urls are mutually exclusive (use --terminal-urls; --terminal-url is the singular back-compat alias)")
		os.Exit(2)
	}
	parsedTabs, terr := parseTerminalURLs(*terminalURLs, *terminalURL)
	if terr != nil {
		fmt.Fprintf(os.Stderr, "boring-ui-backend: %v\n", terr)
		os.Exit(2)
	}

	// --mock back-compat: if the bool flag is set, force provider=mock.
	if *mock {
		*provider = "mock"
	}

	switch *provider {
	case "mock":
		// nothing to verify
	case "claude":
		ok, reason := claudeAvailable()
		if !ok {
			fmt.Fprintf(os.Stderr, "boring-ui-backend: --provider claude unavailable: %s\n", reason)
			os.Exit(2)
		}
	default:
		fmt.Fprintf(os.Stderr, "boring-ui-backend: unknown --provider %q (want: mock | claude)\n", *provider)
		os.Exit(2)
	}

	parsedAllowed := parseAllowedPaths(*allowedPaths)
	if len(parsedAllowed) > 0 && !isGitRepo(*workdir) {
		fmt.Fprintf(os.Stderr,
			"boring-ui-backend: --allowed-paths requires workdir to be a git repository; %s is not (git rev-parse --git-dir failed). Reactive enforcement uses git checkout to revert out-of-allowlist writes.\n",
			*workdir)
		os.Exit(2)
	}

	if err := run(*socketPath, *slug, *workdir, *threadsDir, *previewURL, *previewPort, parsedTabs, *provider, parsedAllowed); err != nil {
		log.Fatalf("boring-ui-backend: %v", err)
	}
}

func run(socketPath, slug, workdir, threadsDir, previewURL string, previewPort int, terminalTabs []TerminalTab, provider string, allowedPaths []string) error {
	// Set up the socket directory + remove any stale socket from a prior run.
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return fmt.Errorf("create socket dir: %w", err)
	}
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove stale socket: %w", err)
	}

	thread, err := NewThread(threadsDir, slug)
	if err != nil {
		return fmt.Errorf("init thread: %w", err)
	}
	log.Printf("thread file: %s", thread.Path())

	b := NewBroadcaster()
	defer b.Close()

	// NewServer's terminalURL string arg is the v0.12.0 single-iframe shape;
	// pass "" here and populate TerminalTabs (ARD-0035) directly. activeTerminalTabs
	// resolves the legacy field for older callers, so this is the canonical path
	// for any v0.13.0+ invocation.
	srv := NewServer(slug, workdir, previewURL, "", provider, allowedPaths, b, thread)
	srv.TerminalTabs = terminalTabs

	// Dedicated-origin preview proxy (ARD-0033): when both an upstream URL and
	// a port are configured, the right-pane iframe loads http://127.0.0.1:<port>/
	// and a second HTTP server on that port reverse-proxies to previewURL with
	// X-Frame-Options + CSP frame-ancestors stripped. Served at root so the
	// upstream's root-absolute asset URLs (/cdn/..., /checkouts/...) resolve back
	// into the proxy rather than escaping to the host proxy's frame-blocked root.
	var previewSrv *http.Server
	var previewListener net.Listener
	if previewURL != "" && previewPort != 0 {
		ph, perr := newPreviewProxyHandler(previewURL)
		if perr != nil {
			return fmt.Errorf("preview proxy: %w", perr)
		}
		addr := fmt.Sprintf("127.0.0.1:%d", previewPort)
		if ln, lerr := net.Listen("tcp", addr); lerr != nil {
			// A preview-port collision must NOT take down the chat UI. Degrade
			// to the "no preview configured" fallback (PreviewFrameURL stays "")
			// and keep serving the rest.
			log.Printf("preview proxy: cannot bind %s (%v); preview disabled, chat UI unaffected", addr, lerr)
		} else {
			previewListener = ln
			srv.PreviewFrameURL = fmt.Sprintf("http://127.0.0.1:%d/", previewPort)
			previewSrv = &http.Server{
				Handler:           ph,
				ReadHeaderTimeout: 10 * time.Second,
				// Long timeouts: HMR websockets + streaming upstreams stay open.
				ReadTimeout:  0,
				WriteTimeout: 0,
				IdleTimeout:  120 * time.Second,
			}
		}
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", socketPath, err)
	}
	// 0600: only the owner (the user running the container) can dial. The
	// proxy verifies ownership before dialing (boring-proxy proxy.go).
	if err := os.Chmod(socketPath, 0o600); err != nil {
		return fmt.Errorf("chmod socket: %w", err)
	}

	httpSrv := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// Long timeouts: SSE streams have to stay open.
		ReadTimeout:  0,
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	go func() {
		<-ctx.Done()
		log.Printf("shutting down on signal")
		shutdownCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = httpSrv.Shutdown(shutdownCtx)
		if previewSrv != nil {
			_ = previewSrv.Shutdown(shutdownCtx)
		}
	}()

	// Start the dedicated-origin preview proxy (if configured) before the main
	// server. A serve error here is logged but non-fatal — the chat UI keeps
	// working even if the preview listener dies.
	if previewSrv != nil {
		log.Printf("preview proxy serving on %s -> %s (frame-blocking headers stripped, ARD-0033)", previewListener.Addr(), previewURL)
		go func() {
			if err := previewSrv.Serve(previewListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Printf("preview proxy serve error: %v", err)
			}
		}()
	}

	log.Printf("boring-ui-backend serving slug=%s provider=%s on %s", slug, provider, socketPath)
	if len(allowedPaths) > 0 {
		log.Printf("reactive path-allowlist enforcement enabled: %v", allowedPaths)
	}

	if err := httpSrv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}
