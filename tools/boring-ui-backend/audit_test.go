// audit_test.go — FIFO bridge round-trip + best-effort no-op behavior.
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// withFIFO points auditFIFOPath at a fresh temp FIFO with a registered reader
// (O_RDONLY|O_NONBLOCK so the open returns immediately AND the writer's
// non-blocking open sees a reader). Returns the reader; restores the path on
// cleanup.
func withFIFO(t *testing.T) *os.File {
	t.Helper()
	fifo := filepath.Join(t.TempDir(), "events.fifo")
	if err := syscall.Mkfifo(fifo, 0o622); err != nil {
		t.Fatalf("mkfifo: %v", err)
	}
	rf, err := os.OpenFile(fifo, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	orig := auditFIFOPath
	auditFIFOPath = fifo
	t.Cleanup(func() {
		auditFIFOPath = orig
		rf.Close()
	})
	return rf
}

func TestEmitAudit_RoundTrip(t *testing.T) {
	rf := withFIFO(t)
	t.Setenv("BORING_PROFILE_NAME", "marketing-site")
	t.Setenv("BORING_HOST_USER", "tom")

	emitAudit("guardrail_violation", "claude", PolicyBlockedData{
		Path:   "secret.env",
		Reason: "outside allowed_paths",
	})

	got := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(rf).ReadString('\n')
		got <- line
	}()

	select {
	case line := <-got:
		var ev auditEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("event is not valid JSON: %v (line=%q)", err, line)
		}
		if ev.Kind != "guardrail_violation" {
			t.Errorf("kind=%q want guardrail_violation", ev.Kind)
		}
		if ev.Agent != "claude" {
			t.Errorf("agent=%q want claude", ev.Agent)
		}
		if ev.Profile != "marketing-site" {
			t.Errorf("profile=%q want marketing-site", ev.Profile)
		}
		if ev.User != "tom" {
			t.Errorf("user=%q want tom", ev.User)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no event read from FIFO")
	}
}

func TestEmitAudit_MissingFIFOIsNoOp(t *testing.T) {
	orig := auditFIFOPath
	auditFIFOPath = filepath.Join(t.TempDir(), "does-not-exist.fifo")
	t.Cleanup(func() { auditFIFOPath = orig })

	// Must not panic or block — a missing FIFO (audit not wired) is the
	// normal case and a turn must proceed regardless.
	done := make(chan struct{})
	go func() {
		emitAudit("guardrail_violation", "claude", PolicyBlockedData{Path: "x", Reason: "y"})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("emitAudit blocked on a missing FIFO")
	}
}
