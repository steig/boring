// server_test.go — HTTP handler tests for the v0 boring-ui backend.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T, mock bool) (*Server, *httptest.Server) {
	t.Helper()
	provider := "claude" // arbitrary non-mock placeholder; tests of the claude
	if mock {            // path inject TurnRunner so this never spawns claude.
		provider = "mock"
	}
	return newTestServerProvider(t, provider)
}

// newTestServerProvider lets tests pick the provider explicitly.
func newTestServerProvider(t *testing.T, provider string) (*Server, *httptest.Server) {
	t.Helper()
	dir := t.TempDir()
	th, err := NewThread(dir, "test")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	s := NewServer("test", t.TempDir(), "", "", provider, nil, b, th)
	// Disable save shell-out for tests; the runSave fakeSaveSucceeded path is
	// exercised separately.
	s.SaveCmd = nil
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(func() {
		srv.Close()
		b.Close()
	})
	return s, srv
}

func TestIndexServed(t *testing.T) {
	_, srv := newTestServer(t, false)
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !bytes.Contains(body, []byte("boring chat")) {
		t.Errorf("index missing expected title; got %s", string(body[:min(200, len(body))]))
	}
}

func TestIndexPreviewFallbackWhenURLEmpty(t *testing.T) {
	// newTestServer constructs the Server with preview URL "" (see helper).
	_, srv := newTestServer(t, false)
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if bytes.Contains(body, []byte("{{PREVIEW_PANE}}")) {
		t.Errorf("template marker not substituted: %s", string(body[:min(400, len(body))]))
	}
	if !bytes.Contains(body, []byte("No preview configured")) {
		t.Errorf("expected fallback copy; got %s", string(body[:min(400, len(body))]))
	}
	if bytes.Contains(body, []byte("<iframe")) {
		t.Errorf("expected no iframe with empty preview URL; got %s", string(body[:min(400, len(body))]))
	}
}

func TestIndexPreviewIframeWhenURLSet(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "test")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	t.Cleanup(b.Close)
	s := NewServer("test", t.TempDir(), "http://localhost:3000/", "", "mock", nil, b, th)
	s.SaveCmd = nil
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if bytes.Contains(body, []byte("{{PREVIEW_PANE}}")) {
		t.Errorf("template marker not substituted: %s", string(body[:min(400, len(body))]))
	}
	// Per ARD-0031: iframe src is the relative /preview/ path (same-origin),
	// not the absolute URL. The header strip (asserted in
	// TestIndexPreviewHeaderRendersWhenURLSet) still surfaces the absolute
	// URL so the user knows what's being proxied.
	want := `src="/preview/"`
	if !bytes.Contains(body, []byte(want)) {
		t.Errorf("expected iframe %s; got %s", want, string(body[:min(400, len(body))]))
	}
	if !bytes.Contains(body, []byte(`id="preview-iframe"`)) {
		t.Errorf("expected iframe id=preview-iframe; got %s", string(body[:min(400, len(body))]))
	}
	// The absolute URL should NOT appear as the iframe src (would defeat
	// the same-origin-via-proxy design).
	if bytes.Contains(body, []byte(`src="http://localhost:3000/"`)) {
		t.Errorf("iframe still has absolute src; expected relative /preview/. body: %s",
			string(body[:min(400, len(body))]))
	}
	if bytes.Contains(body, []byte("No preview configured")) {
		t.Errorf("fallback copy leaked through when URL was set")
	}
}

func TestIndexPreviewHeaderRendersWhenURLSet(t *testing.T) {
	// When --preview-url is set, the preview pane should also include a
	// header strip with refresh button, open-in-new-tab link, and the URL.
	dir := t.TempDir()
	th, err := NewThread(dir, "test")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	t.Cleanup(b.Close)
	s := NewServer("test", t.TempDir(), "http://localhost:3000/", "", "mock", nil, b, th)
	s.SaveCmd = nil
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	mustContain := []string{
		`class="preview-header"`,                                // header strip
		`id="preview-refresh"`,                                  // refresh button
		`id="preview-open"`,                                     // open-in-new-tab link
		`href="http://localhost:3000/"`,                         // link target
		`target="_blank"`,                                       // opens new tab
		`rel="noopener noreferrer"`,                             // safe link
		`localhost:3000/`,                                       // muted URL display (scheme stripped)
		`class="preview-url"`,                                   // URL element
	}
	for _, want := range mustContain {
		if !bytes.Contains(body, []byte(want)) {
			t.Errorf("preview header missing %q in:\n%s", want, string(body[:min(800, len(body))]))
		}
	}
}

func TestIndexPreviewHeaderAbsentWhenURLEmpty(t *testing.T) {
	// The fallback case must NOT render the header strip — empty URL means
	// nothing for the refresh/open buttons to act on.
	_, srv := newTestServer(t, false) // newTestServer uses empty preview URL
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	for _, forbidden := range []string{`preview-header`, `id="preview-refresh"`, `id="preview-open"`} {
		if bytes.Contains(body, []byte(forbidden)) {
			t.Errorf("preview header leaked through with empty URL: found %q in:\n%s",
				forbidden, string(body[:min(800, len(body))]))
		}
	}
}

func TestIndexPreviewURLEscaped(t *testing.T) {
	// Defense-in-depth: even though --preview-url is operator-controlled,
	// the substitution must HTML-attribute-escape the URL so a malformed
	// flag value can't break out of src="...".
	dir := t.TempDir()
	th, err := NewThread(dir, "test")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	t.Cleanup(b.Close)
	s := NewServer("test", t.TempDir(), `http://x/"><script>alert(1)</script>`, "", "mock", nil, b, th)
	s.SaveCmd = nil
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if bytes.Contains(body, []byte("<script>alert(1)</script>")) {
		t.Errorf("unescaped script tag in output: %s", string(body[:min(400, len(body))]))
	}
}

func TestAssetsServed(t *testing.T) {
	_, srv := newTestServer(t, false)
	for _, path := range []string{"/chat.css", "/chat.js"} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("%s status=%d", path, resp.StatusCode)
		}
	}
}

func TestThreadMethodNotAllowed(t *testing.T) {
	_, srv := newTestServer(t, false)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/thread", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST /api/thread: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("status=%d want 405", resp.StatusCode)
	}
	if got := resp.Header.Get("Allow"); got != "GET" {
		t.Errorf("Allow=%q want GET", got)
	}
}

func TestMessagesRejectsEmpty(t *testing.T) {
	_, srv := newTestServer(t, true)
	resp, err := http.Post(srv.URL+"/api/messages", "application/json", strings.NewReader(`{"text":""}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status=%d want 400", resp.StatusCode)
	}
}

func TestMessagesRejectsBadJSON(t *testing.T) {
	_, srv := newTestServer(t, true)
	resp, err := http.Post(srv.URL+"/api/messages", "application/json", strings.NewReader(`not json`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status=%d want 400", resp.StatusCode)
	}
}

// TestSSEFullMockFlow is the end-to-end interface test: post a message,
// receive the mocked event sequence on the SSE stream.
func TestSSEFullMockFlow(t *testing.T) {
	_, srv := newTestServer(t, true)

	// Open the SSE stream first so we don't miss the events.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/events", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /api/events: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("SSE status=%d", resp.StatusCode)
	}

	// Small delay to ensure subscribe runs before publish.
	time.Sleep(50 * time.Millisecond)

	// Post the message in a goroutine — the mock fires events over ~2s.
	go func() {
		r, err := http.Post(srv.URL+"/api/messages", "application/json",
			strings.NewReader(`{"text":"hello"}`))
		if err == nil {
			r.Body.Close()
		}
	}()

	// Read the SSE stream until we see turn_complete (or timeout).
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	got := []string{}
	deadline := time.After(5 * time.Second)
	currentType := ""

readLoop:
	for {
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for events; got so far: %v", got)
		default:
		}
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				t.Fatalf("scan: %v", err)
			}
			break
		}
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "event: "):
			currentType = strings.TrimPrefix(line, "event: ")
		case line == "" && currentType != "":
			got = append(got, currentType)
			if currentType == "turn_complete" {
				break readLoop
			}
			currentType = ""
		}
	}

	// Want at least: user_message, ai_thinking, tool_call, tool_result, turn_complete.
	want := []string{"user_message", "ai_thinking", "tool_call", "tool_result", "turn_complete"}
	if len(got) < len(want) {
		t.Fatalf("got %d events, want at least %d: %v", len(got), len(want), got)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("event %d: got %q want %q (full: %v)", i, got[i], w, got)
		}
	}
}

func TestThreadHydration(t *testing.T) {
	s, srv := newTestServer(t, false)

	// Seed the thread directly.
	for _, txt := range []string{"a", "b"} {
		env, err := s.Broadcaster.NewEnvelope(EventUserMessage, UserMessageData{Text: txt})
		if err != nil {
			t.Fatalf("envelope: %v", err)
		}
		_ = s.Thread.Append(env)
	}

	resp, err := http.Get(srv.URL + "/api/thread")
	if err != nil {
		t.Fatalf("GET /api/thread: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Slug   string     `json:"slug"`
		Events []Envelope `json:"events"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Slug != "test" {
		t.Errorf("slug=%q want test", body.Slug)
	}
	if len(body.Events) != 2 {
		t.Errorf("events=%d want 2", len(body.Events))
	}
}

func TestSavePreviewReturnsTitle(t *testing.T) {
	s, srv := newTestServer(t, false)
	env, _ := s.Broadcaster.NewEnvelope(EventUserMessage, UserMessageData{Text: "make a new thing"})
	_ = s.Thread.Append(env)

	resp, err := http.Get(srv.URL + "/api/save/preview")
	if err != nil {
		t.Fatalf("GET /api/save/preview: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Title       string `json:"title"`
		Description string `json:"description"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Title != "make a new thing" {
		t.Errorf("title=%q want %q", body.Title, "make a new thing")
	}
	if body.Description == "" {
		t.Errorf("description is empty")
	}
}

// TestSaveFakeFlow: with SaveCmd disabled, POST /api/save should still
// produce save_started + save_succeeded events on the SSE stream.
func TestSaveFakeFlow(t *testing.T) {
	s, srv := newTestServer(t, false)

	sub := s.Broadcaster.Subscribe()
	defer s.Broadcaster.Unsubscribe(sub)

	resp, err := http.Post(srv.URL+"/api/save", "application/json", strings.NewReader(`{"title":"t","description":"d"}`))
	if err != nil {
		t.Fatalf("POST /api/save: %v", err)
	}
	resp.Body.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	events := Drain(ctx, sub, 2, 2*time.Second)
	if len(events) < 2 {
		t.Fatalf("got %d events, want 2 (started + succeeded)", len(events))
	}
	if events[0].Type != EventSaveStarted {
		t.Errorf("event 0: %s want %s", events[0].Type, EventSaveStarted)
	}
	if events[1].Type != EventSaveSucceeded {
		t.Errorf("event 1: %s want %s", events[1].Type, EventSaveSucceeded)
	}
	var d SaveSucceededData
	if err := json.Unmarshal(events[1].Data, &d); err != nil {
		t.Errorf("save_succeeded data: %v", err)
	}
	if d.PRURL == "" || d.BranchName == "" {
		t.Errorf("save_succeeded missing fields: %+v", d)
	}
}

func TestThreadPersistsAcrossServerRestart(t *testing.T) {
	dir := t.TempDir()
	th, err := NewThread(dir, "persist")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	defer b.Close()
	s := NewServer("persist", t.TempDir(), "", "", "mock", nil, b, th)
	s.SaveCmd = nil

	srv1 := httptest.NewServer(s.Handler())
	// Post a message; let mock run to completion (sleeps total ~1.9s).
	resp, err := http.Post(srv1.URL+"/api/messages", "application/json", strings.NewReader(`{"text":"persist me"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	resp.Body.Close()
	time.Sleep(2200 * time.Millisecond)
	srv1.Close()

	// "Restart": new Server + Thread reading the same directory.
	th2, err := NewThread(dir, "persist")
	if err != nil {
		t.Fatalf("NewThread again: %v", err)
	}
	b2 := NewBroadcaster()
	defer b2.Close()
	s2 := NewServer("persist", t.TempDir(), "", "", "mock", nil, b2, th2)
	s2.SaveCmd = nil
	srv2 := httptest.NewServer(s2.Handler())
	defer srv2.Close()

	resp, err = http.Get(srv2.URL + "/api/thread")
	if err != nil {
		t.Fatalf("GET /api/thread: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Events []Envelope `json:"events"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Events) < 5 {
		t.Fatalf("expected >=5 events from mock turn, got %d", len(body.Events))
	}
	if body.Events[0].Type != EventUserMessage {
		t.Errorf("first event: %s want %s", body.Events[0].Type, EventUserMessage)
	}
}

func TestUndoStub(t *testing.T) {
	s, srv := newTestServer(t, false)
	sub := s.Broadcaster.Subscribe()
	defer s.Broadcaster.Unsubscribe(sub)

	resp, err := http.Post(srv.URL+"/api/undo", "application/json", strings.NewReader(`{"event_id":"evt-7"}`))
	if err != nil {
		t.Fatalf("POST /api/undo: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status=%d", resp.StatusCode)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	got := Drain(ctx, sub, 1, time.Second)
	if len(got) != 1 {
		t.Fatalf("expected 1 event, got %d", len(got))
	}
	if got[0].Type != EventToolResult {
		t.Errorf("type=%s want %s", got[0].Type, EventToolResult)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
