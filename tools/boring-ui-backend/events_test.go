// events_test.go — broadcaster pub/sub + envelope behaviors. Run under
// -race for the goroutine paths.
package main

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"
)

func TestBroadcasterFanOut(t *testing.T) {
	b := NewBroadcaster()
	defer b.Close()

	const n = 4
	subs := make([]chan Envelope, n)
	for i := range subs {
		subs[i] = b.Subscribe()
	}

	env, err := b.NewEnvelope(EventUserMessage, UserMessageData{Text: "hello"})
	if err != nil {
		t.Fatalf("NewEnvelope: %v", err)
	}
	b.Publish(env)

	for i, ch := range subs {
		select {
		case got := <-ch:
			if got.Type != EventUserMessage {
				t.Errorf("sub %d: type=%s want %s", i, got.Type, EventUserMessage)
			}
			var d UserMessageData
			if err := json.Unmarshal(got.Data, &d); err != nil {
				t.Errorf("sub %d: data unmarshal: %v", i, err)
			} else if d.Text != "hello" {
				t.Errorf("sub %d: text=%q want %q", i, d.Text, "hello")
			}
		case <-time.After(time.Second):
			t.Fatalf("sub %d: timed out", i)
		}
	}
}

func TestBroadcasterUnsubscribe(t *testing.T) {
	b := NewBroadcaster()
	defer b.Close()

	a := b.Subscribe()
	c := b.Subscribe()
	b.Unsubscribe(a)

	// a should be closed.
	select {
	case _, ok := <-a:
		if ok {
			t.Errorf("a: expected closed channel, got value")
		}
	case <-time.After(time.Second):
		t.Errorf("a: expected channel to be closed immediately after Unsubscribe")
	}

	env, _ := b.NewEnvelope(EventAIThinking, struct{}{})
	b.Publish(env)

	// c still receives.
	select {
	case got := <-c:
		if got.Type != EventAIThinking {
			t.Errorf("c: type=%s", got.Type)
		}
	case <-time.After(time.Second):
		t.Errorf("c: expected event after unsubscribe of a")
	}
}

func TestBroadcasterClose(t *testing.T) {
	b := NewBroadcaster()
	a := b.Subscribe()
	b.Close()

	select {
	case _, ok := <-a:
		if ok {
			t.Errorf("expected closed channel after Close()")
		}
	case <-time.After(time.Second):
		t.Errorf("channel not closed after Close()")
	}

	// Post-close subscribe returns a pre-closed channel.
	z := b.Subscribe()
	select {
	case _, ok := <-z:
		if ok {
			t.Errorf("post-close subscribe returned non-closed channel")
		}
	case <-time.After(time.Second):
		t.Errorf("post-close subscribe channel did not close")
	}

	// Publish post-close is a no-op (no panic).
	env, _ := b.NewEnvelope(EventTurnComplete, struct{}{})
	b.Publish(env)
}

func TestBroadcasterConcurrentPubSub(t *testing.T) {
	// Race-detector target: many subscribers and publishers running
	// concurrently. We don't assert delivery counts (we drop on full
	// buffer); we assert no panic and no data race.
	b := NewBroadcaster()
	defer b.Close()

	const (
		nPub = 8
		nSub = 8
		nEv  = 200
	)

	var wg sync.WaitGroup
	// Subscribers churn: subscribe, drain a few, unsubscribe.
	for i := 0; i < nSub; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ch := b.Subscribe()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = Drain(ctx, ch, 5, 100*time.Millisecond)
			b.Unsubscribe(ch)
		}()
	}
	// Publishers.
	for i := 0; i < nPub; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for j := 0; j < nEv; j++ {
				env, err := b.NewEnvelope(EventToolCall, ToolCallData{
					Tool: "test",
					Args: json.RawMessage(`{"k":"v"}`),
				})
				if err != nil {
					t.Errorf("NewEnvelope: %v", err)
					return
				}
				b.Publish(env)
			}
		}(i)
	}
	wg.Wait()
}

func TestEnvelopeIDMonotonic(t *testing.T) {
	b := NewBroadcaster()
	defer b.Close()

	a, _ := b.NewEnvelope(EventAIThinking, struct{}{})
	c, _ := b.NewEnvelope(EventAIThinking, struct{}{})
	if a.ID == c.ID {
		t.Errorf("IDs collide: %s == %s", a.ID, c.ID)
	}
	if a.TS == "" || c.TS == "" {
		t.Errorf("missing timestamps")
	}
}
