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
