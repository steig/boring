package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestRegistryParsesFixture — known-shape registry round-trips cleanly.
func TestRegistryParsesFixture(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "registry.json")
	fixture := `{
  "projects": [
    {
      "slug": "marketing-site",
      "name": "Marketing Site",
      "path": "/Users/alice/code/marketing-site",
      "status": "running",
      "socket": "/tmp/boring/marketing-site.sock",
      "summary": "Updating hero text"
    },
    {
      "slug": "help-center",
      "name": "Help Center",
      "path": "/Users/alice/code/help-center",
      "status": "stopped",
      "last_active": "2026-05-24T18:00:00Z"
    }
  ]
}`
	if err := os.WriteFile(p, []byte(fixture), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	r, err := NewRegistry(p)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	if got := len(r.List()); got != 2 {
		t.Errorf("want 2 projects, got %d", got)
	}
	ms, ok := r.Get("marketing-site")
	if !ok {
		t.Fatalf("marketing-site not found")
	}
	if ms.Status != "running" {
		t.Errorf("status = %q, want running", ms.Status)
	}
	if ms.Socket != "/tmp/boring/marketing-site.sock" {
		t.Errorf("socket = %q, unexpected", ms.Socket)
	}
	if ms.Summary != "Updating hero text" {
		t.Errorf("summary = %q, want 'Updating hero text'", ms.Summary)
	}
}

// TestRegistryMissingFileIsEmpty — no file == empty registry, no error.
func TestRegistryMissingFileIsEmpty(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "does-not-exist.json")
	r, err := NewRegistry(p)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	if got := len(r.List()); got != 0 {
		t.Errorf("want 0 projects, got %d", got)
	}
}

// TestRegistryReloadPicksUpChanges — write, reload, see the new state.
func TestRegistryReloadPicksUpChanges(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(p, []byte(`{"projects":[]}`), 0o644)
	r, _ := NewRegistry(p)

	_ = os.WriteFile(p, []byte(`{"projects":[{"slug":"alpha","name":"Alpha","status":"running"}]}`), 0o644)
	if err := r.reload(); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if _, ok := r.Get("alpha"); !ok {
		t.Errorf("alpha not present after reload")
	}
}

// TestRegistrySkipsEmptySlug — entries without a slug are dropped.
func TestRegistrySkipsEmptySlug(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "registry.json")
	_ = os.WriteFile(p, []byte(`{"projects":[{"name":"no slug"},{"slug":"ok","name":"OK"}]}`), 0o644)
	r, _ := NewRegistry(p)
	if got := len(r.List()); got != 1 {
		t.Errorf("want 1 (skipping empty slug), got %d", got)
	}
}

// TestDefaultSocketPath — fall-through chain XDG -> TMPDIR -> /tmp.
func TestDefaultSocketPath(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")
	if got := defaultSocketPath("foo"); got != "/run/user/1000/boring/foo.sock" {
		t.Errorf("XDG path wrong: %q", got)
	}
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("TMPDIR", "/tmp-test")
	if got := defaultSocketPath("foo"); got != "/tmp-test/boring/foo.sock" {
		t.Errorf("TMPDIR path wrong: %q", got)
	}
}
