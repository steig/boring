// registry.go — read and watch ~/.local/share/boring/registry.json.
// The picker reads the registry; the router resolves project slug to per-project
// Unix socket. fsnotify watches the file for boring open/close changes.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/fsnotify/fsnotify"
)

// Project is the registry entry the proxy cares about. Additional fields in
// the on-disk JSON are ignored — registry is owned by `boring`, this is a
// reader-only contract.
type Project struct {
	Slug       string `json:"slug"`
	Name       string `json:"name"`
	Path       string `json:"path"`
	Status     string `json:"status"` // "running", "stopped", "starting", "error"
	Socket     string `json:"socket"` // Unix socket path; empty = default location
	LastActive string `json:"last_active"`
	Summary    string `json:"summary"` // one-line AI-generated chat summary (ARD-0021 §3)
}

// registryFile is the on-disk shape: {"projects": [...]}.
type registryFile struct {
	Projects []Project `json:"projects"`
}

// Registry is the in-memory, watcher-backed view of the projects registry.
type Registry struct {
	path string

	mu         sync.RWMutex
	projects   map[string]Project
	reloadHook func() // optional, fired after a successful reload
}

// SetReloadHook registers a callback fired after every successful reload.
// Used by the router to drop cached reverse proxies when the registry changes.
func (r *Registry) SetReloadHook(fn func()) {
	r.mu.Lock()
	r.reloadHook = fn
	r.mu.Unlock()
}

// NewRegistry loads the registry from path. A missing file is fine — starts empty.
func NewRegistry(path string) (*Registry, error) {
	r := &Registry{path: path, projects: map[string]Project{}}
	if err := r.reload(); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	return r, nil
}

// reload reads the registry file and rebuilds the in-memory map. Entries
// with invalid socket paths are dropped with a log line (per security review
// critical-5) so a malicious registry can't point the proxy at, e.g.,
// /var/run/docker.sock. On parse error, prior in-memory state is preserved.
func (r *Registry) reload() error {
	data, err := os.ReadFile(r.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			r.mu.Lock()
			r.projects = map[string]Project{}
			r.mu.Unlock()
			return err
		}
		return fmt.Errorf("read registry: %w", err)
	}

	var parsed registryFile
	if err := json.Unmarshal(data, &parsed); err != nil {
		// Per security review (regression test): on parse error, keep prior state.
		return fmt.Errorf("parse registry: %w", err)
	}

	next := make(map[string]Project, len(parsed.Projects))
	for _, p := range parsed.Projects {
		if p.Slug == "" {
			continue
		}
		if !isValidSlug(p.Slug) {
			log.Printf("registry: rejecting entry with invalid slug %q", p.Slug)
			continue
		}
		if p.Socket != "" {
			if err := validateSocketPath(p.Socket); err != nil {
				log.Printf("registry: rejecting project %q: %v", p.Slug, err)
				continue
			}
		}
		next[p.Slug] = p
	}
	r.mu.Lock()
	r.projects = next
	hook := r.reloadHook
	r.mu.Unlock()
	if hook != nil {
		hook()
	}
	return nil
}

// validateSocketPath enforces socket paths live under one of the expected
// runtime dirs and have a .sock suffix. Refuses ".." and absolute paths
// outside the allowlist. Per security review (critical-5).
func validateSocketPath(sock string) error {
	if !strings.HasSuffix(sock, ".sock") {
		return fmt.Errorf("socket %q lacks .sock suffix", sock)
	}
	if strings.Contains(sock, "..") {
		return fmt.Errorf("socket %q contains '..'", sock)
	}
	clean := filepath.Clean(sock)
	allowedPrefixes := socketAllowedPrefixes()
	for _, p := range allowedPrefixes {
		if strings.HasPrefix(clean, p) {
			return nil
		}
	}
	return fmt.Errorf("socket %q not under any allowed prefix %v", clean, allowedPrefixes)
}

// socketAllowedPrefixes returns the directories under which we accept project
// sockets: $XDG_RUNTIME_DIR/boring/, $TMPDIR/boring/, /tmp/boring/.
func socketAllowedPrefixes() []string {
	out := []string{}
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		out = append(out, filepath.Join(d, "boring")+string(os.PathSeparator))
	}
	if d := os.Getenv("TMPDIR"); d != "" {
		out = append(out, filepath.Join(d, "boring")+string(os.PathSeparator))
	}
	out = append(out, "/tmp/boring"+string(os.PathSeparator))
	return out
}

// Get returns the project for a slug, false if not registered.
func (r *Registry) Get(slug string) (Project, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.projects[slug]
	return p, ok
}

// List returns all projects (snapshot copy).
func (r *Registry) List() []Project {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Project, 0, len(r.projects))
	for _, p := range r.projects {
		out = append(out, p)
	}
	return out
}

// Count returns the current project count under the read lock. Used by Watch
// to avoid a data race on r.projects in the log line (per security review
// critical-3).
func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.projects)
}

// Watch reloads the registry when the file (or its parent dir) changes.
// Blocks until ctx is done. fsnotify deduplicates rapid writes naturally —
// editors that do atomic-rename are handled by watching the parent dir.
func (r *Registry) Watch(ctx context.Context) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("registry watcher disabled: %v", err)
		return
	}
	defer w.Close()

	// Watch parent dir so atomic-renames (write-temp + rename) still fire.
	dir := filepath.Dir(r.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Printf("registry: mkdir %s: %v", dir, err)
		return
	}
	if err := w.Add(dir); err != nil {
		log.Printf("registry: watch %s: %v", dir, err)
		return
	}

	target := filepath.Base(r.path)
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			if filepath.Base(ev.Name) != target {
				continue
			}
			if err := r.reload(); err != nil && !errors.Is(err, fs.ErrNotExist) {
				log.Printf("registry reload: %v", err)
			} else {
				// Per security review (critical-3): use Count() under RLock
				// instead of len(r.projects) bare to avoid the data race.
				log.Printf("registry: reloaded (%d projects)", r.Count())
			}
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			log.Printf("registry watcher error: %v", err)
		}
	}
}

// DataDir returns the boring data directory ($BORING_DATA_DIR or
// $HOME/.local/share/boring). Mirrors lib/core.sh's DATA_DIR. Returns an
// error if neither env var nor $HOME is resolvable — per security review
// (high-11), no silent fallback to ".".
func DataDir() (string, error) {
	if d := os.Getenv("BORING_DATA_DIR"); d != "" {
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home dir: %w", err)
	}
	return filepath.Join(home, ".local", "share", "boring"), nil
}
