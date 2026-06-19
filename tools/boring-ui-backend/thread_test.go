// thread_test.go — JSONL append/read + malformed-line tolerance.
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestThreadAppendAndRead(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "demo")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}

	b := NewBroadcaster()
	defer b.Close()

	for i, txt := range []string{"hello", "world", "third"} {
		env, err := b.NewEnvelope(EventUserMessage, UserMessageData{Text: txt})
		if err != nil {
			t.Fatalf("envelope %d: %v", i, err)
		}
		if err := th.Append(env); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}

	got, err := th.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 envelopes, got %d", len(got))
	}
	for i, want := range []string{"hello", "world", "third"} {
		var d UserMessageData
		if err := json.Unmarshal(got[i].Data, &d); err != nil {
			t.Errorf("data %d: %v", i, err)
		}
		if d.Text != want {
			t.Errorf("env %d: text=%q want %q", i, d.Text, want)
		}
	}
}

func TestThreadReadMissingFile(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "fresh")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	got, err := th.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll on missing file should be nil error, got %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty, got %d", len(got))
	}
}

func TestThreadMalformedLines(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "broken")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}

	// Hand-write a file with a good line, a bad line, an empty line, another good.
	good1 := `{"id":"evt-1","ts":"2026-05-25T00:00:00Z","type":"user_message","data":{"text":"a"}}`
	good2 := `{"id":"evt-2","ts":"2026-05-25T00:00:01Z","type":"user_message","data":{"text":"b"}}`
	content := good1 + "\n" + "not json at all" + "\n\n" + good2 + "\n"
	if err := os.WriteFile(th.Path(), []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	got, err := th.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 valid envelopes, got %d", len(got))
	}
	if got[0].ID != "evt-1" || got[1].ID != "evt-2" {
		t.Errorf("ids: %s, %s", got[0].ID, got[1].ID)
	}
}

func TestThreadConcurrentAppend(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "concurrent")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()

	const n = 50
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			env, err := b.NewEnvelope(EventUserMessage, UserMessageData{Text: "msg"})
			if err != nil {
				t.Errorf("envelope: %v", err)
				return
			}
			if err := th.Append(env); err != nil {
				t.Errorf("append: %v", err)
			}
		}(i)
	}
	wg.Wait()

	got, err := th.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != n {
		t.Errorf("expected %d envelopes, got %d (concurrent append may have torn lines)", n, len(got))
	}
}

func TestThreadFallbackDir(t *testing.T) {
	// Pass a directory under a read-only path so MkdirAll fails; expect the
	// fallback to kick in. On macOS, /System/Volumes/Data is typically not
	// writable to a normal user; on Linux, /proc/1/X is the conservative pick.
	// To keep the test portable, we craft an unwriteable parent: create a
	// file, then ask for a child of that file (NotADir).
	parent := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(parent, []byte("x"), 0o644); err != nil {
		t.Fatalf("write blocker: %v", err)
	}
	bad := filepath.Join(parent, "threads") // child of a file: MkdirAll fails

	th, err := NewThread(bad, "fb")
	if err != nil {
		t.Fatalf("NewThread should fall back, got %v", err)
	}
	// Should be a usable path.
	b := NewBroadcaster()
	defer b.Close()
	env, _ := b.NewEnvelope(EventUserMessage, UserMessageData{Text: "fb"})
	if err := th.Append(env); err != nil {
		t.Fatalf("append on fallback: %v", err)
	}
	got, err := th.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll on fallback: %v", err)
	}
	if len(got) != 1 {
		t.Errorf("expected 1, got %d", len(got))
	}
}

func TestSummarizeSinceLastSave(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "summary")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()

	// First, an empty thread.
	s, err := th.SummarizeSinceLastSave()
	if err != nil {
		t.Fatalf("Summarize empty: %v", err)
	}
	if s == "" {
		t.Errorf("expected non-empty placeholder, got empty")
	}

	// Append user msg + tool call.
	u, _ := b.NewEnvelope(EventUserMessage, UserMessageData{Text: "update the hero"})
	_ = th.Append(u)
	tc, _ := b.NewEnvelope(EventToolCall, ToolCallData{Tool: "file_edit", Args: json.RawMessage(`{}`)})
	_ = th.Append(tc)
	s, err = th.SummarizeSinceLastSave()
	if err != nil {
		t.Fatalf("Summarize: %v", err)
	}
	if s != "update the hero" {
		t.Errorf("summary=%q want %q", s, "update the hero")
	}

	// Save event resets the window.
	sv, _ := b.NewEnvelope(EventSaveSucceeded, SaveSucceededData{PRURL: "x", BranchName: "y"})
	_ = th.Append(sv)
	s, err = th.SummarizeSinceLastSave()
	if err != nil {
		t.Fatalf("Summarize post-save: %v", err)
	}
	if s == "update the hero" {
		t.Errorf("summary should reset after save, still got %q", s)
	}
}

// ============================================================================
// ComputeSaveContext — richer pre-fill for the save dialog (code-review Fix B)
// ============================================================================

func TestComputeSaveContextEmpty(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "empty")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	ctx, err := th.ComputeSaveContext()
	if err != nil {
		t.Fatalf("ComputeSaveContext: %v", err)
	}
	if ctx.Title != "No new changes to save" {
		t.Errorf("empty title = %q, want 'No new changes to save'", ctx.Title)
	}
	if len(ctx.Prompts) != 0 || len(ctx.Files) != 0 {
		t.Errorf("empty thread should produce no prompts/files; got %v / %v", ctx.Prompts, ctx.Files)
	}
}

func TestComputeSaveContextHappyPath(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "happy")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()

	// Two user prompts, three Edit tool calls (one duplicate file_path to
	// confirm dedupe), one Bash without a path field (must be ignored).
	mk := func(typ EventType, data interface{}) {
		t.Helper()
		env, err := b.NewEnvelope(typ, data)
		if err != nil {
			t.Fatalf("envelope: %v", err)
		}
		if err := th.Append(env); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	mk(EventUserMessage, UserMessageData{Text: "Update the hero CTA"})
	mk(EventToolCall, ToolCallData{
		Tool: "Edit",
		Args: json.RawMessage(`{"file_path":"theme/sections/hero.liquid","old_string":"a","new_string":"b"}`),
	})
	mk(EventToolCall, ToolCallData{
		Tool: "Edit",
		Args: json.RawMessage(`{"file_path":"theme/assets/main.css","old_string":"x","new_string":"y"}`),
	})
	mk(EventUserMessage, UserMessageData{Text: "Also center the logo"})
	mk(EventToolCall, ToolCallData{
		Tool: "Write",
		Args: json.RawMessage(`{"file_path":"theme/sections/hero.liquid","content":"..."}`), // duplicate
	})
	mk(EventToolCall, ToolCallData{
		Tool: "Bash",
		Args: json.RawMessage(`{"command":"echo hi"}`), // no file_path/path
	})

	ctx, err := th.ComputeSaveContext()
	if err != nil {
		t.Fatalf("ComputeSaveContext: %v", err)
	}

	// Title = last user prompt.
	if ctx.Title != "Also center the logo" {
		t.Errorf("title=%q want %q", ctx.Title, "Also center the logo")
	}

	// Prompts preserved in order.
	wantPrompts := []string{"Update the hero CTA", "Also center the logo"}
	if len(ctx.Prompts) != len(wantPrompts) {
		t.Fatalf("got %d prompts (%v); want %d", len(ctx.Prompts), ctx.Prompts, len(wantPrompts))
	}
	for i, p := range wantPrompts {
		if ctx.Prompts[i] != p {
			t.Errorf("prompt[%d]=%q want %q", i, ctx.Prompts[i], p)
		}
	}

	// Files deduped, Bash ignored.
	wantFiles := []string{"theme/sections/hero.liquid", "theme/assets/main.css"}
	if len(ctx.Files) != len(wantFiles) {
		t.Fatalf("got %d files (%v); want %d", len(ctx.Files), ctx.Files, len(wantFiles))
	}
	for i, f := range wantFiles {
		if ctx.Files[i] != f {
			t.Errorf("file[%d]=%q want %q", i, ctx.Files[i], f)
		}
	}
}

func TestComputeSaveContextTitleTrimmedTo80(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "long")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()

	long := "Make the hero section much more visually striking with a gradient background and bigger text and also center everything"
	env, _ := b.NewEnvelope(EventUserMessage, UserMessageData{Text: long})
	if err := th.Append(env); err != nil {
		t.Fatalf("append: %v", err)
	}

	ctx, err := th.ComputeSaveContext()
	if err != nil {
		t.Fatalf("ComputeSaveContext: %v", err)
	}
	if len(ctx.Title) != 80 {
		t.Errorf("title length=%d want 80 (got %q)", len(ctx.Title), ctx.Title)
	}
	if ctx.Title[len(ctx.Title)-3:] != "..." {
		t.Errorf("title should end with ellipsis; got %q", ctx.Title)
	}
	// Full prompt retained in Prompts even if Title is trimmed.
	if len(ctx.Prompts) != 1 || ctx.Prompts[0] != long {
		t.Errorf("full prompt should be in Prompts; got %v", ctx.Prompts)
	}
}

func TestComputeSaveContextAgentsSeen(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "agents")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()

	mk := func(typ EventType, data interface{}) {
		env, _ := b.NewEnvelope(typ, data)
		_ = th.Append(env)
	}

	// One claude tool call, one codex tool call, one un-attributed (legacy)
	// tool call. AgentsSeen should be sorted ["claude","codex"]; the empty
	// agent is dropped (not "unknown" or "claude"-by-default; ARD-0035
	// explicitly chose not to guess).
	mk(EventUserMessage, UserMessageData{Text: "Update hero"})
	mk(EventToolCall, ToolCallData{
		Tool:  "Edit",
		Args:  json.RawMessage(`{"file_path":"hero.liquid"}`),
		Agent: "claude",
	})
	mk(EventToolCall, ToolCallData{
		Tool:  "Edit",
		Args:  json.RawMessage(`{"file_path":"footer.liquid"}`),
		Agent: "codex",
	})
	mk(EventToolCall, ToolCallData{
		Tool: "Edit",
		Args: json.RawMessage(`{"file_path":"old.liquid"}`),
		// Agent intentionally empty (simulates legacy/pre-v0.13.0 events).
	})

	ctx, err := th.ComputeSaveContext()
	if err != nil {
		t.Fatalf("ComputeSaveContext: %v", err)
	}
	want := []string{"claude", "codex"}
	if len(ctx.AgentsSeen) != len(want) {
		t.Fatalf("AgentsSeen=%v want %v", ctx.AgentsSeen, want)
	}
	for i, w := range want {
		if ctx.AgentsSeen[i] != w {
			t.Errorf("AgentsSeen[%d]=%q want %q", i, ctx.AgentsSeen[i], w)
		}
	}
}

func TestComputeSaveContextNoAgentsForLegacy(t *testing.T) {
	// Tool calls written without the Agent field (pre-v0.13.0) must produce
	// an empty AgentsSeen — NOT a guessed default like "claude" — so the
	// description footer doesn't lie about the source.
	dir := t.TempDir()
	th, err := NewThread(dir, "legacy")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()
	env, _ := b.NewEnvelope(EventUserMessage, UserMessageData{Text: "old session"})
	_ = th.Append(env)
	env, _ = b.NewEnvelope(EventToolCall, ToolCallData{
		Tool: "Edit",
		Args: json.RawMessage(`{"file_path":"x.liquid"}`),
	})
	_ = th.Append(env)

	ctx, err := th.ComputeSaveContext()
	if err != nil {
		t.Fatalf("ComputeSaveContext: %v", err)
	}
	if len(ctx.AgentsSeen) != 0 {
		t.Errorf("legacy thread should produce empty AgentsSeen; got %v", ctx.AgentsSeen)
	}
}

func TestComputeSaveContextResetsAfterSaveSucceeded(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "reset")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()

	mk := func(typ EventType, data interface{}) {
		env, _ := b.NewEnvelope(typ, data)
		_ = th.Append(env)
	}

	// First session.
	mk(EventUserMessage, UserMessageData{Text: "Old prompt"})
	mk(EventToolCall, ToolCallData{Tool: "Edit", Args: json.RawMessage(`{"file_path":"old.liquid"}`)})
	mk(EventSaveSucceeded, SaveSucceededData{PRURL: "https://example/pr/1", BranchName: "marketer/old-..."})

	// Second session.
	mk(EventUserMessage, UserMessageData{Text: "New prompt"})
	mk(EventToolCall, ToolCallData{Tool: "Edit", Args: json.RawMessage(`{"file_path":"new.liquid"}`)})

	ctx, err := th.ComputeSaveContext()
	if err != nil {
		t.Fatalf("ComputeSaveContext: %v", err)
	}
	if ctx.Title != "New prompt" {
		t.Errorf("title=%q want 'New prompt' (old session must be excluded)", ctx.Title)
	}
	if len(ctx.Prompts) != 1 || ctx.Prompts[0] != "New prompt" {
		t.Errorf("prompts=%v want [New prompt]", ctx.Prompts)
	}
	if len(ctx.Files) != 1 || ctx.Files[0] != "new.liquid" {
		t.Errorf("files=%v want [new.liquid]", ctx.Files)
	}
}
