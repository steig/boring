// events.go — SSE event broadcaster + envelope schema.
//
// Event envelope (matches ARD-0010's audit pipeline shape so the audit
// collector can consume the same JSONL later):
//
//	{
//	  "id":   "evt-...",                  // monotonic per-process
//	  "ts":   "2026-05-25T03:00:00Z",     // RFC3339
//	  "type": "user_message",             // see EventType constants below
//	  "data": { ... type-specific ... }
//	}
//
// On the SSE wire each event is emitted as:
//
//	event: <type>\n
//	data: <json of envelope.Data, NOT the whole envelope>\n
//	id: <envelope.ID>\n
//	\n
//
// The client uses EventSource.addEventListener("<type>", ...) to dispatch.
// Storage (thread.jsonl) keeps the FULL envelope (id+ts+type+data) on each
// line — that way replay/audit has everything; live SSE has the type as the
// event header and the data as the payload.
//
// Event types (ARD-0022 §4 card types, plus a few protocol-level ones):
//
//	user_message     {"text": string}                              — user typed
//	ai_thinking      {}                                            — spinner up
//	ai_text          {"text": string}                              — AI prose reply
//	tool_call        {"tool": string, "args": object}              — tool start
//	tool_result      {"tool": string, "result_summary": string,    — tool done
//	                  "diff": string?}
//	turn_complete    {"cost_usd": number?, "duration_ms": number?, — AI done
//	                  "error": string?}
//	lock_status      {"holder": string, "last_active": string}     — presence
//	save_started     {}                                            — save begin
//	save_succeeded   {"pr_url": string, "branch_name": string}     — save ok
//	save_failed      {"error": string, "recoverable": bool}        — save err
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// EventType is the SSE `event:` header value and the discriminator on the
// stored JSONL envelope.
type EventType string

const (
	EventUserMessage   EventType = "user_message"
	EventAIThinking    EventType = "ai_thinking"
	EventAIText        EventType = "ai_text"
	EventToolCall      EventType = "tool_call"
	EventToolResult    EventType = "tool_result"
	EventTurnComplete  EventType = "turn_complete"
	EventLockStatus    EventType = "lock_status"
	EventSaveStarted   EventType = "save_started"
	EventSaveSucceeded EventType = "save_succeeded"
	EventSaveFailed    EventType = "save_failed"
	// EventPolicyBlocked is emitted by the post-turn enforcement pass when a
	// file modified by the AI falls outside the configured allowed_paths.
	// The file is reverted via git before this event lands.
	EventPolicyBlocked EventType = "policy_blocked"
)

// Envelope is the persisted shape on the JSONL thread + the in-memory shape
// passed through the broadcaster.
type Envelope struct {
	ID   string          `json:"id"`
	TS   string          `json:"ts"`
	Type EventType       `json:"type"`
	Data json.RawMessage `json:"data"`
}

// --- Typed data payloads (Go-side helpers; clients see JSON shapes above) ---

type UserMessageData struct {
	Text string `json:"text"`
}

// AITextData is the AI's prose reply for one assistant message block. One
// AI turn may emit zero, one, or multiple of these (one per text block).
type AITextData struct {
	Text string `json:"text"`
}

// TurnCompleteData carries optional turn metadata. All fields are optional;
// the mock emits an empty object, the claude provider fills in cost/duration
// when the upstream `result` event provides them. Error is set only on
// non-success turn termination.
type TurnCompleteData struct {
	CostUSD    float64 `json:"cost_usd,omitempty"`
	DurationMS int64   `json:"duration_ms,omitempty"`
	Error      string  `json:"error,omitempty"`
}

type ToolCallData struct {
	Tool string          `json:"tool"`
	Args json.RawMessage `json:"args"`
	// Agent is the harness that produced this tool call: "claude" | "codex"
	// (ARD-0035). Empty for legacy events written before v0.13.0 — readers
	// should treat empty as "unknown" rather than defaulting to claude, so
	// SaveContext's agent-set rendering doesn't lie about the source.
	Agent string `json:"agent,omitempty"`
}

type ToolResultData struct {
	Tool          string `json:"tool"`
	ResultSummary string `json:"result_summary"`
	Diff          string `json:"diff,omitempty"`
}

type LockStatusData struct {
	Holder     string `json:"holder"`
	LastActive string `json:"last_active"`
}

type SaveSucceededData struct {
	PRURL      string `json:"pr_url"`
	BranchName string `json:"branch_name"`
}

type SaveFailedData struct {
	Error       string `json:"error"`
	Recoverable bool   `json:"recoverable"`
}

// PolicyBlockedData carries the reverted file path + a human-readable reason
// for the chat UI to render the red-bordered card. v0 sets Reason to
// "outside allowed_paths" for the normal case; revert failures append the
// underlying git error so the engineer can debug.
type PolicyBlockedData struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// Broadcaster is a fan-out SSE pub/sub. Multiple subscribers receive every
// published envelope; slow subscribers are dropped (bounded channel + non-
// blocking send) rather than backpressuring the publisher — v0 prototype.
type Broadcaster struct {
	mu     sync.Mutex
	subs   map[chan Envelope]struct{}
	closed bool

	idSeq atomic.Uint64
}

// NewBroadcaster returns an empty broadcaster.
func NewBroadcaster() *Broadcaster {
	return &Broadcaster{subs: map[chan Envelope]struct{}{}}
}

// Subscribe returns a channel that receives every Publish after this point.
// Caller must call Unsubscribe on the returned channel when done. Buffer
// size 64 — generous for v0; a slow subscriber drops events past that.
func (b *Broadcaster) Subscribe() chan Envelope {
	ch := make(chan Envelope, 64)
	b.mu.Lock()
	if !b.closed {
		b.subs[ch] = struct{}{}
	} else {
		close(ch)
	}
	b.mu.Unlock()
	return ch
}

// Unsubscribe removes ch from the subscriber set and closes it. Safe to call
// multiple times (the close is the guard).
func (b *Broadcaster) Unsubscribe(ch chan Envelope) {
	b.mu.Lock()
	if _, ok := b.subs[ch]; ok {
		delete(b.subs, ch)
		close(ch)
	}
	b.mu.Unlock()
}

// Publish fans out env to every subscriber. Non-blocking send per subscriber;
// if the subscriber's buffer is full, the event is dropped for that subscriber
// (it's a UI prototype, not a payment processor).
func (b *Broadcaster) Publish(env Envelope) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return
	}
	for ch := range b.subs {
		select {
		case ch <- env:
		default:
			// Buffer full — drop on the floor. v0.
		}
	}
}

// Close shuts down the broadcaster, closing every subscriber channel. Further
// Publish calls are no-ops; further Subscribe calls return a pre-closed chan.
func (b *Broadcaster) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return
	}
	b.closed = true
	for ch := range b.subs {
		close(ch)
	}
	b.subs = map[chan Envelope]struct{}{}
}

// NewEnvelope builds an envelope with a unique ID + current timestamp,
// marshalling data to JSON. Returns an error only if data is unmarshalable
// (programmer error in practice).
func (b *Broadcaster) NewEnvelope(t EventType, data any) (Envelope, error) {
	raw, err := json.Marshal(data)
	if err != nil {
		return Envelope{}, fmt.Errorf("marshal event data: %w", err)
	}
	id := fmt.Sprintf("evt-%d", b.idSeq.Add(1))
	return Envelope{
		ID:   id,
		TS:   time.Now().UTC().Format(time.RFC3339Nano),
		Type: t,
		Data: raw,
	}, nil
}

// Drain is a test helper: reads up to n envelopes from ch with a per-event
// timeout. Returns whatever arrived before timeout. Stops early on close.
func Drain(ctx context.Context, ch <-chan Envelope, n int, perEvent time.Duration) []Envelope {
	out := make([]Envelope, 0, n)
	for i := 0; i < n; i++ {
		t := time.NewTimer(perEvent)
		select {
		case env, ok := <-ch:
			t.Stop()
			if !ok {
				return out
			}
			out = append(out, env)
		case <-t.C:
			return out
		case <-ctx.Done():
			t.Stop()
			return out
		}
	}
	return out
}
