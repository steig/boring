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
//	                  --mock
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
		socketPath = flag.String("socket", "", "Unix socket path to listen on (required)")
		slug       = flag.String("slug", "", "project slug (required)")
		workdir    = flag.String("workdir", "", "project working directory (required)")
		threadsDir = flag.String("threads-dir", DefaultThreadsDir, "directory for thread JSONL files")
		mock       = flag.Bool("mock", false, "use mock AI event generator instead of real OpenCode")
	)
	flag.Parse()

	if *socketPath == "" || *slug == "" || *workdir == "" {
		fmt.Fprintln(os.Stderr, "usage: boring-ui-backend --socket <path> --slug <name> --workdir <path> [--mock]")
		os.Exit(2)
	}

	if err := run(*socketPath, *slug, *workdir, *threadsDir, *mock); err != nil {
		log.Fatalf("boring-ui-backend: %v", err)
	}
}

func run(socketPath, slug, workdir, threadsDir string, mock bool) error {
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

	srv := NewServer(slug, workdir, mock, b, thread)

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
	}()

	mode := "real"
	if mock {
		mode = "MOCK"
	}
	log.Printf("boring-ui-backend serving slug=%s mode=%s on %s", slug, mode, socketPath)

	if err := httpSrv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}
