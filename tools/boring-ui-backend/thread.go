// thread.go — append-only JSONL persistence for the per-project chat thread.
//
// Storage: one file per project at /var/lib/boring-ui/threads/<slug>.jsonl.
// Each line is one Envelope (see events.go). New events are appended;
// readers do a one-shot full read for chat hydration. v0 prototype: no
// pagination, no compaction. ARD-0022 §1 — single thread per project.
//
// Robustness notes:
//   - If the configured directory can't be created (permissions, RO mount),
//     we fall back to a temp dir and log a warning. v0: keep it running.
//   - Append uses O_APPEND; concurrent appends from one process are
//     serialized via a mutex so a JSONL line can't be torn. We do NOT
//     guard against multi-process append (Linux O_APPEND is atomic up to
//     PIPE_BUF for small writes, but full event lines can exceed that —
//     v0 ignores the multi-process case; one backend process per slug).
//   - Read tolerates malformed lines (logs + skips); doesn't blow up.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// DefaultThreadsDir is the standard container-side location per ARD-0022 §9.
const DefaultThreadsDir = "/var/lib/boring-ui/threads"

// Thread is a single project's chat thread, appended to on every event.
type Thread struct {
	path string

	mu sync.Mutex
}

// NewThread opens (or creates) the thread file at <dir>/<slug>.jsonl. If
// <dir> can't be made (permissions), falls back to a temp dir and logs.
// The returned Thread is usable immediately; Append serializes writes.
func NewThread(dir, slug string) (*Thread, error) {
	if slug == "" {
		return nil, errors.New("thread: slug required")
	}
	resolved := dir
	if err := os.MkdirAll(resolved, 0o755); err != nil {
		// v0 fallback: temp dir keeps the prototype running on dev laptops
		// where /var/lib/boring-ui/ doesn't exist or isn't writable. Use
		// MkdirTemp so concurrent backends don't share a directory (and so
		// tests don't pollute each other).
		fallback, err2 := os.MkdirTemp("", "boring-ui-threads-")
		if err2 != nil {
			return nil, fmt.Errorf("thread: cannot create dir %s (%v) or fallback (%v)", dir, err, err2)
		}
		log.Printf("thread: %s not writable (%v), falling back to %s", dir, err, fallback)
		resolved = fallback
	}
	return &Thread{path: filepath.Join(resolved, slug+".jsonl")}, nil
}

// Path returns the on-disk JSONL path. Test/diagnostic helper.
func (t *Thread) Path() string { return t.path }

// Append serializes env to JSON and writes one line. Atomic per-line at the
// process level (mutex-guarded + single write call).
func (t *Thread) Append(env Envelope) error {
	line, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("thread: marshal envelope: %w", err)
	}
	line = append(line, '\n')

	t.mu.Lock()
	defer t.mu.Unlock()
	f, err := os.OpenFile(t.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("thread: open %s: %w", t.path, err)
	}
	defer f.Close()
	if _, err := f.Write(line); err != nil {
		return fmt.Errorf("thread: write %s: %w", t.path, err)
	}
	return nil
}

// ReadAll loads every envelope from the JSONL file in order. Missing file
// returns empty slice + nil error (fresh thread). Malformed lines are logged
// and skipped — partial recovery beats hard fail for v0 prototype.
func (t *Thread) ReadAll() ([]Envelope, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	f, err := os.Open(t.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("thread: open %s: %w", t.path, err)
	}
	defer f.Close()

	var out []Envelope
	scanner := bufio.NewScanner(f)
	// Allow long lines (large diffs in tool_result events). 1 MiB initial,
	// 16 MiB cap — v0 prototype; tighten later if needed.
	scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)

	lineNo := 0
	for scanner.Scan() {
		lineNo++
		raw := strings.TrimSpace(scanner.Text())
		if raw == "" {
			continue
		}
		var env Envelope
		if err := json.Unmarshal([]byte(raw), &env); err != nil {
			log.Printf("thread: skipping malformed line %d in %s: %v", lineNo, t.path, err)
			continue
		}
		out = append(out, env)
	}
	if err := scanner.Err(); err != nil {
		return out, fmt.Errorf("thread: scan %s: %w", t.path, err)
	}
	return out, nil
}

// SaveContext is the rich pre-fill payload for the save dialog. It's what
// ComputeSaveContext returns and what handleSavePreview formats into the PR
// title + description. Beyond a title-shaped string, it carries every user
// prompt since the last save and the unique files Claude touched, so the
// PR body can lead with what the marketer actually asked for — not just a
// diff the engineer reviewer has to interpret cold (the gap called out in
// the code review of the ARD-0035 work).
type SaveContext struct {
	Title       string   // last user prompt, trimmed to 80 chars; "No new changes to save" when empty
	Prompts     []string // every user prompt in order, since the last save_succeeded
	Files       []string // unique file paths from Edit/Write/MultiEdit/Read tool calls (best-effort: scans ToolCall args for file_path/path keys)
	AgentsSeen  []string // unique agent names ("claude", "codex") that emitted at least one tool call since the last save (ARD-0035); empty for legacy threads written before v0.13.0
}

// ComputeSaveContext walks the thread since the last save_succeeded and
// extracts (a) every user prompt and (b) the file paths Claude touched.
// v0: file extraction is a best-effort scan of ToolCall args for "file_path"
// / "path" keys (matches Claude's Edit/Write/MultiEdit/Read tool schemas;
// any future tool that uses a different key shape will silently be missed
// from the files list — falls back to "no files" gracefully).
func (t *Thread) ComputeSaveContext() (SaveContext, error) {
	ctx := SaveContext{}
	all, err := t.ReadAll()
	if err != nil {
		return ctx, err
	}

	// Same "since last save" anchor SummarizeSinceLastSave uses, so the two
	// helpers stay consistent.
	startIdx := 0
	for i := len(all) - 1; i >= 0; i-- {
		if all[i].Type == EventSaveSucceeded {
			startIdx = i + 1
			break
		}
	}
	events := all[startIdx:]
	if len(events) == 0 {
		ctx.Title = "No new changes to save"
		return ctx, nil
	}

	seenFiles := map[string]bool{}
	seenAgents := map[string]bool{}
	for _, e := range events {
		switch e.Type {
		case EventUserMessage:
			var d UserMessageData
			if err := json.Unmarshal(e.Data, &d); err == nil {
				if text := strings.TrimSpace(d.Text); text != "" {
					ctx.Prompts = append(ctx.Prompts, text)
					// Title := most recent prompt (matches the prior
					// SummarizeSinceLastSave behavior — "what they asked most
					// recently" is a reasonable PR-title shape).
					ctx.Title = text
				}
			}
		case EventToolCall:
			var d ToolCallData
			if err := json.Unmarshal(e.Data, &d); err != nil {
				continue
			}
			// Track agent attribution (ARD-0035): an empty d.Agent means the
			// event predates v0.13.0 (the field was added then) — exclude
			// from AgentsSeen rather than guess, so the description footer
			// doesn't lie about who did what.
			if d.Agent != "" && !seenAgents[d.Agent] {
				seenAgents[d.Agent] = true
				ctx.AgentsSeen = append(ctx.AgentsSeen, d.Agent)
			}
			// Decode args as a flat string→raw map and pick out path-shaped
			// keys. Edit/Write/MultiEdit use "file_path"; some Bash/Read
			// variants use "path". Anything else is ignored — extracting
			// touched files from `Bash` (e.g. `sed -i ...`) is out of scope
			// for v0 (would require shell-AST parsing).
			var args map[string]json.RawMessage
			if err := json.Unmarshal(d.Args, &args); err != nil {
				continue
			}
			for _, key := range []string{"file_path", "path"} {
				raw, ok := args[key]
				if !ok {
					continue
				}
				var p string
				if err := json.Unmarshal(raw, &p); err != nil {
					continue
				}
				if p == "" || seenFiles[p] {
					continue
				}
				seenFiles[p] = true
				ctx.Files = append(ctx.Files, p)
			}
		}
	}
	sort.Strings(ctx.AgentsSeen) // stable rendering: claude before codex, alphabetic.

	// Title shaping: trim to 80 chars for PR-title compatibility. If no user
	// prompts were captured, fall back to a count-based summary so the
	// dialog never opens blank.
	if ctx.Title == "" {
		ctx.Title = fmt.Sprintf("boring-ui session (%d prompt(s), %d file(s))", len(ctx.Prompts), len(ctx.Files))
	}
	if len(ctx.Title) > 80 {
		ctx.Title = ctx.Title[:77] + "..."
	}
	return ctx, nil
}

// SummarizeSinceLastSave returns a short, deterministic summary of events
// since the last save_succeeded (or from the start of the thread if no save
// ever happened). v0: a one-liner counting tool_calls + user messages and
// echoing the most recent user_message text. Real summarization is a
// post-MVP AI call; this is a stub so the save dialog has *something*.
//
// Retained as the title-only path for any caller that doesn't need the
// fuller SaveContext shape; handleSavePreview itself switched to
// ComputeSaveContext.
func (t *Thread) SummarizeSinceLastSave() (string, error) {
	all, err := t.ReadAll()
	if err != nil {
		return "", err
	}
	// Find index after the last save_succeeded.
	startIdx := 0
	for i := len(all) - 1; i >= 0; i-- {
		if all[i].Type == EventSaveSucceeded {
			startIdx = i + 1
			break
		}
	}
	events := all[startIdx:]
	if len(events) == 0 {
		return "No new changes to save", nil
	}
	var (
		userMsgs  int
		toolCalls int
		lastUser  string
	)
	for _, e := range events {
		switch e.Type {
		case EventUserMessage:
			userMsgs++
			var d UserMessageData
			if err := json.Unmarshal(e.Data, &d); err == nil {
				lastUser = d.Text
			}
		case EventToolCall:
			toolCalls++
		}
	}
	if lastUser != "" {
		// Trim to ~80 chars for a title-shaped summary.
		title := strings.TrimSpace(lastUser)
		if len(title) > 80 {
			title = title[:77] + "..."
		}
		return title, nil
	}
	return fmt.Sprintf("%d message(s), %d tool call(s)", userMsgs, toolCalls), nil
}
