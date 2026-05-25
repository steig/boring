// policy_test.go — unit tests for the reactive path-allowlist enforcement
// (ARD-0029 §6 gap #1 backstop). Tests that use git create a real tempdir
// repo via `git init` + commit — git is a project dep already and this is
// the cleanest way to exercise the revert path end-to-end.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
)

// --- pathAllowed ---------------------------------------------------------

func TestPathAllowed_ExactMatch(t *testing.T) {
	if !pathAllowed("README.md", []string{"README.md"}) {
		t.Errorf("exact match should be allowed")
	}
	if pathAllowed("README.md", []string{"OTHER.md"}) {
		t.Errorf("non-matching exact should be blocked")
	}
}

func TestPathAllowed_GlobstarMatches(t *testing.T) {
	cases := []struct {
		name    string
		path    string
		pattern string
		want    bool
	}{
		{"nested under **", "web/src/lib/Auth.svelte", "web/src/**", true},
		{"shallow under **", "web/src/index.js", "web/src/**", true},
		{"sibling escape", "web/server/auth.ts", "web/src/**", false},
		{"top-level **", "anything.md", "**", true},
		{"nested ** middle", "a/b/c/d.txt", "a/**/d.txt", true},
		{"dir-prefix shorthand", "templates/sections/hero.liquid", "templates/", true},
		{"dir-prefix shorthand mismatch", "snippets/foo.liquid", "templates/", false},
		{"single * inside segment", "foo.md", "*.md", true},
		{"single * does not cross /", "docs/foo.md", "*.md", false},
		{"multi-pattern any matches", "content/x.md", []string{"web/src/**", "content/**"}[1], true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := pathAllowed(c.path, []string{c.pattern}); got != c.want {
				t.Errorf("pathAllowed(%q, [%q]) = %v want %v", c.path, c.pattern, got, c.want)
			}
		})
	}
}

func TestPathAllowed_MultiplePatternsORs(t *testing.T) {
	allow := []string{"web/src/**", "templates/**", "content/**"}
	for _, p := range []string{"web/src/a.js", "templates/x.liquid", "content/posts/y.md"} {
		if !pathAllowed(p, allow) {
			t.Errorf("expected %q allowed by %v", p, allow)
		}
	}
	for _, p := range []string{"docker-compose.yml", "web/server/auth.ts", ".github/workflows/x.yml"} {
		if pathAllowed(p, allow) {
			t.Errorf("expected %q blocked by %v", p, allow)
		}
	}
}

func TestPathAllowed_DotDotRejected(t *testing.T) {
	// Path traversal must not pass the matcher regardless of allowlist.
	for _, p := range []string{"../etc/passwd", "../../bin/sh", ".."} {
		if pathAllowed(p, []string{"**"}) {
			t.Errorf("path traversal %q must be rejected even with allowlist=[**]", p)
		}
	}
}

func TestPathAllowed_AbsolutePathRejected(t *testing.T) {
	// Absolute paths are never workdir-relative; reject.
	if pathAllowed("/etc/passwd", []string{"**"}) {
		t.Errorf("absolute path must be rejected")
	}
	if pathAllowed("/Users/x/code/file.go", []string{"**"}) {
		t.Errorf("absolute path must be rejected")
	}
}

func TestPathAllowed_EmptyPathRejected(t *testing.T) {
	if pathAllowed("", []string{"**"}) {
		t.Errorf("empty path must be rejected")
	}
}

// --- parseAllowedPaths ---------------------------------------------------

func TestParseAllowedPaths_EmptyInputReturnsEmpty(t *testing.T) {
	for _, in := range []string{"", "   ", "\t", "\n"} {
		got := parseAllowedPaths(in)
		if len(got) != 0 {
			t.Errorf("parseAllowedPaths(%q) = %v want []", in, got)
		}
	}
}

func TestParseAllowedPaths_Trims(t *testing.T) {
	got := parseAllowedPaths("  web/src/** , templates/** , content/**  ")
	want := []string{"web/src/**", "templates/**", "content/**"}
	if !equalStrings(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestParseAllowedPaths_FiltersEmpty(t *testing.T) {
	got := parseAllowedPaths("web/src/**,,, , templates/**")
	want := []string{"web/src/**", "templates/**"}
	if !equalStrings(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

// --- enforceAllowlist (with real git) ------------------------------------

// recordingEmitter captures emitted policy_blocked events for assertion. It's
// safe to call from multiple goroutines because enforceAllowlist is
// sequential in v0; the mutex is defensive.
type recordingEmitter struct {
	mu     sync.Mutex
	events []PolicyBlockedData
}

func (r *recordingEmitter) EmitPolicyBlocked(path, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, PolicyBlockedData{Path: path, Reason: reason})
}

func (r *recordingEmitter) snapshot() []PolicyBlockedData {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]PolicyBlockedData, len(r.events))
	copy(out, r.events)
	return out
}

// initRepo creates a fresh git repo in dir with a single commit containing
// the given initial files. Returns the dir for chaining. Skips the test if
// git isn't on PATH.
func initRepo(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH; skipping enforcement test")
	}
	mustRunGit(t, dir, "init", "-q", "-b", "main")
	// Configure a local user so commits succeed without global config.
	mustRunGit(t, dir, "config", "user.email", "test@example.com")
	mustRunGit(t, dir, "config", "user.name", "Test")
	// Disable any per-repo signing/hooks that might be inherited.
	mustRunGit(t, dir, "config", "commit.gpgsign", "false")

	for path, content := range files {
		full := filepath.Join(dir, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", full, err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", full, err)
		}
	}
	mustRunGit(t, dir, "add", ".")
	mustRunGit(t, dir, "commit", "-q", "-m", "init")
}

func mustRunGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	full := append([]string{"-C", dir}, args...)
	cmd := exec.Command("git", full...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, dir, err, string(out))
	}
}

func writeFile(t *testing.T, dir, path, content string) {
	t.Helper()
	full := filepath.Join(dir, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", full, err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", full, err)
	}
}

func readFile(t *testing.T, dir, path string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, path))
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func TestEnforceAllowlist_NoopWhenEmpty(t *testing.T) {
	dir := t.TempDir()
	initRepo(t, dir, map[string]string{"a.txt": "original\n"})
	// Modify outside any allowlist — should be left alone (empty allowlist).
	writeFile(t, dir, "a.txt", "modified\n")

	rec := &recordingEmitter{}
	blocked, err := enforceAllowlist(dir, nil, rec)
	if err != nil {
		t.Fatalf("enforceAllowlist: %v", err)
	}
	if len(blocked) != 0 {
		t.Errorf("blocked=%v want empty (no enforcement)", blocked)
	}
	if len(rec.snapshot()) != 0 {
		t.Errorf("emitted=%d want 0", len(rec.snapshot()))
	}
	if got := readFile(t, dir, "a.txt"); got != "modified\n" {
		t.Errorf("file should be unchanged by no-op enforcement; got %q", got)
	}
}

func TestEnforceAllowlist_RevertsOutOfAllowlist(t *testing.T) {
	dir := t.TempDir()
	initRepo(t, dir, map[string]string{
		"web/src/index.js": "original src\n",
		"docker-compose.yml": "version: \"3\"\nservices:\n  app:\n    image: nginx\n",
	})
	// Modify one in-allowlist file (should survive) and one out-of-allowlist
	// (should be reverted).
	writeFile(t, dir, "web/src/index.js", "modified src\n")
	writeFile(t, dir, "docker-compose.yml", "HELLO BORING\n")

	rec := &recordingEmitter{}
	blocked, err := enforceAllowlist(dir, []string{"web/src/**"}, rec)
	if err != nil {
		t.Fatalf("enforceAllowlist: %v", err)
	}
	if !equalStrings(blocked, []string{"docker-compose.yml"}) {
		t.Errorf("blocked=%v want [docker-compose.yml]", blocked)
	}

	// In-allowlist file must still be modified.
	if got := readFile(t, dir, "web/src/index.js"); got != "modified src\n" {
		t.Errorf("in-allowlist file should remain modified; got %q", got)
	}
	// Out-of-allowlist file must be reverted to the committed contents.
	want := "version: \"3\"\nservices:\n  app:\n    image: nginx\n"
	if got := readFile(t, dir, "docker-compose.yml"); got != want {
		t.Errorf("out-of-allowlist file should be reverted; got %q want %q", got, want)
	}
}

func TestEnforceAllowlist_PreservesInAllowlist(t *testing.T) {
	dir := t.TempDir()
	initRepo(t, dir, map[string]string{
		"web/src/a.js":          "a\n",
		"web/src/lib/b.js":      "b\n",
		"templates/hero.liquid": "hero\n",
	})
	// Modify multiple in-allowlist files; none should be reverted.
	writeFile(t, dir, "web/src/a.js", "a-mod\n")
	writeFile(t, dir, "web/src/lib/b.js", "b-mod\n")
	writeFile(t, dir, "templates/hero.liquid", "hero-mod\n")

	rec := &recordingEmitter{}
	blocked, err := enforceAllowlist(dir, []string{"web/src/**", "templates/**"}, rec)
	if err != nil {
		t.Fatalf("enforceAllowlist: %v", err)
	}
	if len(blocked) != 0 {
		t.Errorf("blocked=%v want empty (all in allowlist)", blocked)
	}
	for path, want := range map[string]string{
		"web/src/a.js":          "a-mod\n",
		"web/src/lib/b.js":      "b-mod\n",
		"templates/hero.liquid": "hero-mod\n",
	} {
		if got := readFile(t, dir, path); got != want {
			t.Errorf("%s = %q want %q (should not be reverted)", path, got, want)
		}
	}
	if len(rec.snapshot()) != 0 {
		t.Errorf("no events should be emitted when all changes are in-allowlist; got %d", len(rec.snapshot()))
	}
}

func TestEnforceAllowlist_EmitsBlockedEventPerFile(t *testing.T) {
	dir := t.TempDir()
	initRepo(t, dir, map[string]string{
		"web/src/index.js": "ok\n",
		"package.json":     "{}\n",
		"Makefile":         "all:\n\t@echo hi\n",
	})
	// Modify two out-of-allowlist files. Expect one event per blocked file.
	writeFile(t, dir, "package.json", `{"new":true}`)
	writeFile(t, dir, "Makefile", "all:\n\t@echo bye\n")
	writeFile(t, dir, "web/src/index.js", "still ok\n")

	rec := &recordingEmitter{}
	blocked, err := enforceAllowlist(dir, []string{"web/src/**"}, rec)
	if err != nil {
		t.Fatalf("enforceAllowlist: %v", err)
	}
	events := rec.snapshot()
	if len(events) != 2 {
		t.Fatalf("emitted %d events; want 2 (one per blocked file). events=%v blocked=%v", len(events), events, blocked)
	}
	gotPaths := []string{events[0].Path, events[1].Path}
	sort.Strings(gotPaths)
	wantPaths := []string{"Makefile", "package.json"}
	if !equalStrings(gotPaths, wantPaths) {
		t.Errorf("emitted paths=%v want %v", gotPaths, wantPaths)
	}
	for _, e := range events {
		if !strings.Contains(e.Reason, "outside allowed_paths") {
			t.Errorf("event reason=%q should contain 'outside allowed_paths'", e.Reason)
		}
	}
}

func TestEnforceAllowlist_HandlesUntrackedFile(t *testing.T) {
	// A brand-new file (no HEAD entry) outside the allowlist must be
	// removed via git clean, not left on disk. This is the "claude wrote a
	// new file" case.
	dir := t.TempDir()
	initRepo(t, dir, map[string]string{"web/src/index.js": "x\n"})
	writeFile(t, dir, "secrets.env", "DB_PASS=hunter2\n")

	rec := &recordingEmitter{}
	blocked, err := enforceAllowlist(dir, []string{"web/src/**"}, rec)
	if err != nil {
		t.Fatalf("enforceAllowlist: %v", err)
	}
	if !equalStrings(blocked, []string{"secrets.env"}) {
		t.Errorf("blocked=%v want [secrets.env]", blocked)
	}
	if _, err := os.Stat(filepath.Join(dir, "secrets.env")); !os.IsNotExist(err) {
		t.Errorf("untracked out-of-allowlist file should have been removed; stat err=%v", err)
	}
}

func TestIsGitRepo_DetectsCorrectly(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	repoDir := t.TempDir()
	initRepo(t, repoDir, map[string]string{"a.txt": "a\n"})
	if !isGitRepo(repoDir) {
		t.Errorf("isGitRepo(%s) = false; want true", repoDir)
	}
	nonRepo := t.TempDir()
	if isGitRepo(nonRepo) {
		t.Errorf("isGitRepo(%s) = true; want false (no git init)", nonRepo)
	}
}

// --- helpers -------------------------------------------------------------

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
