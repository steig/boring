// policy.go — reactive path-allowlist enforcement (ARD-0029 §6 gap #1).
//
// Backstop for the gap named in ARD-0029 §6: proactive enforcement at claude's
// tool-call layer requires permission-model hooks that don't work reliably for
// fine-grained allow in headless `--print`. The compromise: after each turn
// ends, partition modified files into in-allowlist vs out-of-allowlist, revert
// the out-of-allowlist ones via `git checkout`, emit a policy_blocked event
// per reverted file.
//
// Semantics (per ARD-0022 §5):
//
//   - Allowlist is the resolved (preset default + profile.allowed_paths
//     − profile.disallowed_paths) glob set, passed in as a comma-separated
//     CLI flag. Empty list = no enforcement (back-compat with v0 behavior).
//   - Globstar (**) matches zero or more path segments. Single * matches
//     within one segment. filepath.Match-style otherwise.
//   - Paths are workdir-relative; we reject "..", absolute paths, and any
//     traversal that escapes the workdir.
//   - We enforce on writes only — Reads outside the allowlist are fine for v0
//     (claude needs context). Bash destructive potential is documented as a
//     gap (bash can `> file`, `tee`, `rm`); detection still works via
//     git-status, reverting is the same.
//   - We do NOT handle deletions in v0 — `git status --porcelain` shows them
//     as `D ` lines; v0 ignores. Documented gap.
//
// We stay stdlib-only: shell out to `git` for status + checkout. No go-git.
package main

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// parseAllowedPaths splits a comma-separated CLI flag value into a clean glob
// list. Trims whitespace per entry, drops empties. Returns empty slice for
// empty input — callers treat empty as "no allowlist, no enforcement."
func parseAllowedPaths(commaSep string) []string {
	if strings.TrimSpace(commaSep) == "" {
		return nil
	}
	parts := strings.Split(commaSep, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

// parsePreviewURLs builds the declared preview tab list from the backend's
// flags (ARD-0022 §6 / ARD-0035 preview tabs).
//
// Plural form (--preview-urls): comma-separated "name=port=upstream" entries,
// where port is the host-allocated dedicated-origin proxy port (ARD-0033) for
// that tab. The singular --preview-url/--preview-port folds into a single
// "default" tab. The two forms are mutually exclusive. Tab names must be
// slug-shaped ([a-z0-9-]+) and unique. The upstream keeps any '=' (we split on
// only the first two), so query strings survive. Returns nil,nil when no
// preview is configured (the UI shows its fallback).
func parsePreviewURLs(plural, singularURL string, singularPort int) ([]PreviewTab, error) {
	plural = strings.TrimSpace(plural)
	hasSingular := strings.TrimSpace(singularURL) != "" || singularPort != 0
	if plural != "" && hasSingular {
		return nil, fmt.Errorf("--preview-urls and --preview-url/--preview-port are mutually exclusive")
	}

	if plural == "" {
		if strings.TrimSpace(singularURL) == "" || singularPort == 0 {
			return nil, nil
		}
		return []PreviewTab{{Name: "default", Upstream: strings.TrimSpace(singularURL), Port: singularPort}}, nil
	}

	var tabs []PreviewTab
	seen := make(map[string]bool)
	for _, entry := range strings.Split(plural, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "=", 3)
		if len(parts) != 3 {
			return nil, fmt.Errorf("--preview-urls entry %q must be name=port=upstream", entry)
		}
		name := strings.TrimSpace(parts[0])
		upstream := strings.TrimSpace(parts[2])
		if !isPreviewTabName(name) {
			return nil, fmt.Errorf("--preview-urls: invalid tab name %q (want [a-z0-9-]+)", name)
		}
		if seen[name] {
			return nil, fmt.Errorf("--preview-urls: duplicate tab name %q", name)
		}
		port, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || port <= 0 || port > 65535 {
			return nil, fmt.Errorf("--preview-urls: tab %q has invalid port %q", name, parts[1])
		}
		if upstream == "" {
			return nil, fmt.Errorf("--preview-urls: tab %q has empty upstream", name)
		}
		seen[name] = true
		tabs = append(tabs, PreviewTab{Name: name, Upstream: upstream, Port: port})
	}
	if len(tabs) == 0 {
		return nil, fmt.Errorf("--preview-urls was set but contained no valid entries")
	}
	return tabs, nil
}

// isPreviewTabName reports whether s is a non-empty slug ([a-z0-9-]+) — the
// same shape lib/profile.sh enforces for preview_urls[].name.
func isPreviewTabName(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' {
			return false
		}
	}
	return true
}

// pathAllowed reports whether repoRelPath matches ANY glob in the allowlist.
// repoRelPath is expected to be a clean, workdir-relative path (forward
// slashes, no leading slash, no "..", no "./"). Any other shape is rejected
// (returns false) — a malformed or traversing path is, by policy, never
// "allowed."
//
// Glob support:
//   - "**" matches zero or more path segments (e.g. "web/src/**" matches
//     "web/src/lib/Auth.svelte" AND "web/src/index.js").
//   - "*" matches within a single segment (no path separator).
//   - other characters are literal except "?" and character classes per
//     filepath.Match.
//
// A pattern that is a bare directory prefix (e.g. "web/src/") is treated as
// "web/src/**" so the common ARD-0022 pattern-syntax (templates/, snippets/)
// just works.
//
// Empty allowlist returns false (no enforcement is decided one level up in
// enforceAllowlist; the matcher itself never says "yes" when no policy says
// yes).
func pathAllowed(repoRelPath string, allowlist []string) bool {
	if repoRelPath == "" {
		return false
	}
	// Reject anything that isn't clean-relative.
	if filepath.IsAbs(repoRelPath) {
		return false
	}
	clean := filepath.ToSlash(filepath.Clean(repoRelPath))
	if clean == "." || strings.HasPrefix(clean, "../") || clean == ".." {
		return false
	}
	// filepath.Clean leaves leading "/" alone on abs paths; we already
	// rejected those. But a clean path of "/x" is impossible at this point.

	for _, pat := range allowlist {
		pat = strings.TrimSpace(pat)
		if pat == "" {
			continue
		}
		// Bare directory prefix → treat as "<prefix>**".
		if strings.HasSuffix(pat, "/") {
			pat = pat + "**"
		}
		if matchGlobstar(pat, clean) {
			return true
		}
	}
	return false
}

// matchGlobstar implements ** + * matching against a forward-slash path.
//
// Algorithm: split the pattern on "/" into segments. Walk both pattern segs
// and path segs with two cursors, expanding "**" via recursive try-and-skip.
// Non-globstar segments use filepath.Match for "*" / "?" / character classes.
//
// Examples:
//
//	matchGlobstar("web/src/**", "web/src/lib/auth.ts")   = true
//	matchGlobstar("web/src/**", "web/src/auth.ts")       = true
//	matchGlobstar("web/src/**", "web/src")               = true (zero-seg match)
//	matchGlobstar("web/src/**", "web/server/auth.ts")    = false
//	matchGlobstar("*.md", "foo.md")                      = true
//	matchGlobstar("*.md", "docs/foo.md")                 = false (single * stays in segment)
func matchGlobstar(pattern, path string) bool {
	pSegs := strings.Split(pattern, "/")
	tSegs := strings.Split(path, "/")
	return matchSegs(pSegs, tSegs)
}

func matchSegs(p, t []string) bool {
	for len(p) > 0 {
		head := p[0]
		if head == "**" {
			// Greedy: try matching zero, one, two... target segments.
			rest := p[1:]
			if len(rest) == 0 {
				// Trailing "**" matches the remainder unconditionally.
				return true
			}
			for i := 0; i <= len(t); i++ {
				if matchSegs(rest, t[i:]) {
					return true
				}
			}
			return false
		}
		if len(t) == 0 {
			return false
		}
		ok, err := filepath.Match(head, t[0])
		if err != nil || !ok {
			return false
		}
		p = p[1:]
		t = t[1:]
	}
	return len(t) == 0
}

// gitModifiedFiles returns the relative paths of files MODIFIED or ADDED in
// the workdir tree per `git status --porcelain`. Deletions (`D ` / ` D`) and
// renames (`R `) are ignored in v0 — see policy.go header for the gap note.
//
// The porcelain format is two status chars + space + path. We accept both
// staged (`M ` / `A `) and unstaged (` M` / `??`) variants because the
// claude turn may or may not stage its writes.
func gitModifiedFiles(workdir string) ([]string, error) {
	cmd := exec.Command("git", "-C", workdir, "status", "--porcelain")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git status: %w", err)
	}
	lines := strings.Split(string(out), "\n")
	var paths []string
	for _, line := range lines {
		if len(line) < 4 {
			continue
		}
		// Porcelain: XY <path>. X = staged status, Y = worktree status.
		x := line[0]
		y := line[1]

		// Pick the writes we care about: modified, added, untracked, copied.
		// Skip deletions, renames, ignored.
		isWrite := false
		switch {
		case x == 'M' || y == 'M':
			isWrite = true
		case x == 'A' || y == 'A':
			isWrite = true
		case x == '?' && y == '?':
			isWrite = true // untracked, new file
		case x == 'C' || y == 'C':
			isWrite = true // copied — treat like added
		}
		if !isWrite {
			continue
		}

		// Path starts at column 3 (after XY + space).
		path := line[3:]
		// Renames look like "R  old -> new"; we already excluded those above.
		if strings.Contains(path, " -> ") {
			// Defense: even if a future write status gets the arrow form,
			// take the post-rename path.
			parts := strings.SplitN(path, " -> ", 2)
			path = parts[1]
		}
		// Git may quote paths with spaces / unicode. Strip the surrounding
		// quotes; v0 tolerates the unescaped contents (we ship plain ASCII
		// paths in our tests + the immich smoke).
		path = strings.Trim(path, `"`)
		if path == "" {
			continue
		}
		paths = append(paths, path)
	}
	return paths, nil
}

// gitRevertFile reverts a single workdir-relative path to its HEAD state.
// For untracked files (no HEAD entry), `git checkout HEAD -- <path>` fails;
// we fall back to `git clean -f -- <path>` to remove the new file in that
// case. Errors propagate.
func gitRevertFile(workdir, relPath string) error {
	// Try checkout first.
	cmd := exec.Command("git", "-C", workdir, "checkout", "HEAD", "--", relPath)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	// If checkout failed, the file is likely untracked (no HEAD entry).
	// Remove it via clean. -f is required because clean refuses by default;
	// -- separates flags from paths.
	cmd2 := exec.Command("git", "-C", workdir, "clean", "-f", "--", relPath)
	out2, err2 := cmd2.CombinedOutput()
	if err2 != nil {
		return fmt.Errorf("revert %s: checkout failed (%v: %s); clean also failed (%v: %s)",
			relPath, err, strings.TrimSpace(string(out)), err2, strings.TrimSpace(string(out2)))
	}
	return nil
}

// PolicyEmitter is the surface enforceAllowlist needs to publish events.
// Real callers pass the Broadcaster + Thread; tests pass a stub.
type PolicyEmitter interface {
	EmitPolicyBlocked(path, reason string)
}

// broadcasterPolicyEmitter wires the production Broadcaster + Thread to the
// PolicyEmitter interface. Mirrors the emit-and-persist shape used by mock.go
// and claude.go.
type broadcasterPolicyEmitter struct {
	bcast  *Broadcaster
	thread *Thread
}

func (e *broadcasterPolicyEmitter) EmitPolicyBlocked(path, reason string) {
	env, err := e.bcast.NewEnvelope(EventPolicyBlocked, PolicyBlockedData{
		Path:   path,
		Reason: reason,
	})
	if err != nil {
		return
	}
	_ = e.thread.Append(env)
	e.bcast.Publish(env)
}

// enforceAllowlist runs the post-turn pass. If allowlist is empty, it's a
// no-op (back-compat with v0). Otherwise:
//
//  1. Snapshot the modified-file set via git status.
//  2. Partition into in-allowlist vs out-of-allowlist.
//  3. For each blocked file: revert it, emit policy_blocked.
//  4. Return the list of blocked paths (so the caller can log/attach to logs).
//
// Errors during git status fail the whole pass (no partial enforcement is
// safer than guessing). Per-file revert errors are collected but don't stop
// the loop — one bad path shouldn't strand other reverts.
func enforceAllowlist(workdir string, allowlist []string, emitter PolicyEmitter) ([]string, error) {
	if len(allowlist) == 0 {
		return nil, nil
	}
	modified, err := gitModifiedFiles(workdir)
	if err != nil {
		return nil, err
	}
	var blocked []string
	var firstRevertErr error
	for _, p := range modified {
		if pathAllowed(p, allowlist) {
			continue
		}
		if err := gitRevertFile(workdir, p); err != nil {
			if firstRevertErr == nil {
				firstRevertErr = err
			}
			// Still emit the policy_blocked so the UI tells the user; the
			// file remains modified on disk in this rare error case.
			if emitter != nil {
				emitter.EmitPolicyBlocked(p, "outside allowed_paths (revert failed: "+err.Error()+")")
			}
			blocked = append(blocked, p)
			continue
		}
		if emitter != nil {
			emitter.EmitPolicyBlocked(p, "outside allowed_paths")
		}
		blocked = append(blocked, p)
	}
	if firstRevertErr != nil {
		return blocked, fmt.Errorf("policy enforcement had revert errors; first: %w", firstRevertErr)
	}
	return blocked, nil
}

// isGitRepo returns true if workdir is inside a git work tree. Used at
// startup (main.go) to bail early when --allowed-paths is set but the
// workdir has no git, since enforcement is undefined without it.
func isGitRepo(workdir string) bool {
	cmd := exec.Command("git", "-C", workdir, "rev-parse", "--git-dir")
	return cmd.Run() == nil
}
