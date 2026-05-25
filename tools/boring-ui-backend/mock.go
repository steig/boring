// mock.go — fake OpenCode event generator for v0 prototype.
//
// Real OpenCode integration is gated on subscription verification (ARD-0020).
// Until then, this generator produces a believable event sequence on every
// user message so we can prove the chat-UI flow end-to-end.
//
// Flow when MockTurn is invoked with text "make the hero bigger":
//
//  1. user_message  {text: "make the hero bigger"}             (immediate)
//  2. wait 300ms; ai_thinking
//  3. wait 800ms; tool_call    {tool: "file_edit", args: {path: ...}}
//  4. wait 600ms; tool_result  {tool: "file_edit", result_summary: ...,
//     diff: "<fake unified diff>"}
//  5. wait 200ms; turn_complete
//
// All events go through emit() which publishes to the broadcaster AND appends
// to the thread, so any subscriber gets it live AND it's persisted.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"
)

// MockEmitter ties the broadcaster + thread together for the mock generator.
type MockEmitter struct {
	Broadcaster *Broadcaster
	Thread      *Thread
}

// emit builds an envelope, persists it, and publishes it. Errors are logged
// but never propagated — the user message has already been accepted and
// the UI shouldn't see a 500 just because a downstream emit hiccuped.
func (m *MockEmitter) emit(t EventType, data any) {
	env, err := m.Broadcaster.NewEnvelope(t, data)
	if err != nil {
		log.Printf("mock: envelope build (%s): %v", t, err)
		return
	}
	if err := m.Thread.Append(env); err != nil {
		log.Printf("mock: thread append (%s): %v", t, err)
		// Still publish — losing persistence on one event shouldn't break
		// the live SSE stream the UI is watching.
	}
	m.Broadcaster.Publish(env)
}

// MockTurn runs the full mock sequence for a user message. Blocks until done.
// Caller chooses whether to invoke synchronously (e.g. for tests) or in a
// goroutine (HTTP handler). Cancellable via ctx.
func (m *MockEmitter) MockTurn(ctx context.Context, userText string) {
	// 1. Echo the user message immediately.
	m.emit(EventUserMessage, UserMessageData{Text: userText})

	if !sleepCtx(ctx, 300*time.Millisecond) {
		return
	}

	// 2. AI is thinking.
	m.emit(EventAIThinking, struct{}{})

	if !sleepCtx(ctx, 800*time.Millisecond) {
		return
	}

	// 3. Tool call: file edit.
	argsRaw, _ := json.Marshal(map[string]string{"path": "templates/hero.liquid"})
	m.emit(EventToolCall, ToolCallData{
		Tool: "file_edit",
		Args: argsRaw,
	})

	if !sleepCtx(ctx, 600*time.Millisecond) {
		return
	}

	// 4. Tool result.
	m.emit(EventToolResult, ToolResultData{
		Tool:          "file_edit",
		ResultSummary: fmt.Sprintf("edited 3 lines in templates/hero.liquid"),
		Diff: `--- a/templates/hero.liquid
+++ b/templates/hero.liquid
@@ -1,5 +1,5 @@
 <section class="hero">
-  <h1>Welcome</h1>
-  <p>Shop our collection.</p>
+  <h1>Summer Collection</h1>
+  <p>Discover what's new this season.</p>
 </section>
`,
	})

	if !sleepCtx(ctx, 200*time.Millisecond) {
		return
	}

	// 5. Turn complete.
	m.emit(EventTurnComplete, struct{}{})
}

// sleepCtx sleeps for d unless ctx is cancelled first. Returns true if the
// sleep ran to completion, false if cancelled.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}
