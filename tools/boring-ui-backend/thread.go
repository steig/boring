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

// SummarizeSinceLastSave returns a short, deterministic summary of events
// since the last save_succeeded (or from the start of the thread if no save
// ever happened). v0: a one-liner counting tool_calls + user messages and
// echoing the most recent user_message text. Real summarization is a
// post-MVP AI call; this is a stub so the save dialog has *something*.
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
