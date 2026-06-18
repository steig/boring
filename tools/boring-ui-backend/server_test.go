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
	provider := "claude" // non-mock placeholder; claude-path tests override
	if mock {            // s.Agent with a stub so this never spawns the real CLI.
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

func TestIndexPaneControlsPresent(t *testing.T) {
	// The resize gutter and the two collapse toggles are static markup (bound
	// in chat.js), so they must render regardless of preview/terminal config.
	_, srv := newTestServer(t, false)
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	for _, want := range []string{
		`id="pane-gutter"`,
		`id="toggle-left"`,
		`id="toggle-preview"`,
	} {
		if !bytes.Contains(body, []byte(want)) {
			t.Errorf("expected pane control %s in index; got %s", want, string(body[:min(600, len(body))]))
		}
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
	// ARD-0033: the iframe loads the dedicated preview-proxy origin. Both the
	// upstream URL and the frame URL must be set for the iframe to render.
	s.PreviewFrameURL = "http://127.0.0.1:8765/"
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
	// Per ARD-0033: the iframe src is the dedicated preview-proxy origin
	// (PreviewFrameURL) — an absolute URL on its own port, NOT the upstream and
	// NOT a sub-path. Serving the preview at its own origin root is what lets
	// the upstream's root-absolute asset URLs (/cdn/...) resolve.
	want := `src="http://127.0.0.1:8765/"`
	if !bytes.Contains(body, []byte(want)) {
		t.Errorf("expected iframe %s; got %s", want, string(body[:min(400, len(body))]))
	}
	if !bytes.Contains(body, []byte(`class="preview-iframe"`)) {
		t.Errorf("expected iframe class=preview-iframe; got %s", string(body[:min(400, len(body))]))
	}
	// Guard against the superseded sub-path designs regressing.
	if bytes.Contains(body, []byte(`src="preview/"`)) || bytes.Contains(body, []byte(`src="/preview/"`)) {
		t.Errorf("iframe uses a stale sub-path src; expected the dedicated-origin frame URL. body: %s",
			string(body[:min(400, len(body))]))
	}
	// The UPSTREAM URL must NOT be the iframe src, but SHOULD appear in the
	// header strip (title + open-in-new-tab link) so the user sees/opens it.
	if bytes.Contains(body, []byte(`src="http://localhost:3000/"`)) {
		t.Errorf("iframe src is the upstream; expected the preview-proxy frame URL. body: %s",
			string(body[:min(400, len(body))]))
	}
	if !bytes.Contains(body, []byte(`http://localhost:3000/`)) {
		t.Errorf("upstream URL should still appear in the header strip; body: %s",
			string(body[:min(800, len(body))]))
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
	s.PreviewFrameURL = "http://127.0.0.1:8765/" // ARD-0033: required for the pane to render
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	mustContain := []string{
		`class="preview-header"`,              // header strip
		`class="preview-btn preview-refresh"`, // refresh button (class, not id — N panes)
		`class="preview-btn preview-open"`,    // open-in-new-tab link
		`href="http://localhost:3000/"`,       // link target
		`target="_blank"`,                     // opens new tab
		`rel="noopener noreferrer"`,           // safe link
		`localhost:3000/`,                     // muted URL display (scheme stripped)
		`class="preview-url"`,                 // editable address input
		`class="preview-tabs"`,                // tab strip (ARD-0035)
		`id="preview-tab-add"`,                // runtime add-tab button
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
	for _, forbidden := range []string{`preview-header`, `preview-refresh`, `preview-open`, `preview-tabs`} {
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
	s.PreviewFrameURL = "http://127.0.0.1:8765/" // ARD-0033: required for the pane (with the malicious upstream) to render
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

// recordingProvider is a test AgentProvider that captures the TurnSpec it was
// handed instead of running anything — the stub the claude-dispatch path needs.
type recordingProvider struct{ seen chan TurnSpec }

func (*recordingProvider) Name() string { return "recording" }

func (p *recordingProvider) RunTurn(_ context.Context, spec TurnSpec, _ *Broadcaster, _ *Thread) error {
	p.seen <- spec
	return nil
}

// TestMessagesDispatchToAgent verifies POST /api/messages threads the resolved
// TurnSpec into the injected AgentProvider — the seam ARD-0037 formalizes and
// the removed TurnRunner field never had a test for.
func TestMessagesDispatchToAgent(t *testing.T) {
	s, srv := newTestServerProvider(t, "claude")
	seen := make(chan TurnSpec, 1)
	s.Agent = &recordingProvider{seen: seen}

	resp, err := http.Post(srv.URL+"/api/messages", "application/json",
		strings.NewReader(`{"text":"make the hero bigger"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d want 200", resp.StatusCode)
	}

	select {
	case spec := <-seen:
		if spec.Prompt != "make the hero bigger" {
			t.Errorf("prompt=%q", spec.Prompt)
		}
		if spec.Workdir == "" {
			t.Errorf("workdir not threaded into spec")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("agent never invoked")
	}
}

// TestMessagesThreadsGuardrailsIntoSpec verifies the resolved tool + path
// allowlists on the Server reach the provider via TurnSpec (ARD-0037 §1's
// "thread the resolved guardrails through BuildTurnCommand").
func TestMessagesThreadsGuardrailsIntoSpec(t *testing.T) {
	s, srv := newTestServerProvider(t, "claude")
	s.AllowedTools = []string{"Read", "Grep"}
	s.AllowedPaths = []string{"web/src/**"}
	seen := make(chan TurnSpec, 1)
	s.Agent = &recordingProvider{seen: seen}

	resp, err := http.Post(srv.URL+"/api/messages", "application/json",
		strings.NewReader(`{"text":"hi"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	resp.Body.Close()

	select {
	case spec := <-seen:
		if strings.Join(spec.AllowedTools, ",") != "Read,Grep" {
			t.Errorf("AllowedTools=%v want [Read Grep]", spec.AllowedTools)
		}
		if strings.Join(spec.Allowlist, ",") != "web/src/**" {
			t.Errorf("Allowlist=%v want [web/src/**]", spec.Allowlist)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("agent never invoked")
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

func TestIndexPreviewMultipleTabs(t *testing.T) {
	// ARD-0035: with >1 declared preview tab, renderIndex emits a tab strip and
	// one pane per tab (each its own dedicated-origin iframe).
	dir := t.TempDir()
	th, err := NewThread(dir, "test")
	if err != nil {
		t.Fatalf("NewThread: %v", err)
	}
	b := NewBroadcaster()
	t.Cleanup(b.Close)
	s := NewServer("test", t.TempDir(), "", "", "mock", nil, b, th)
	s.SaveCmd = nil
	s.PreviewTabs = []PreviewTab{
		{Name: "app", Upstream: "http://localhost:3000/", FrameURL: "http://127.0.0.1:8700/"},
		{Name: "docs", Upstream: "http://localhost:8788/", FrameURL: "http://127.0.0.1:8701/"},
	}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	for _, want := range []string{
		`class="preview-tabs"`,           // strip
		`data-pane="0"`, `data-pane="1"`, // two panes/tabs
		`>app</button>`, `>docs</button>`, // tab labels
		`data-frame-url="http://127.0.0.1:8700/"`, // pane 0 proxy
		`data-frame-url="http://127.0.0.1:8701/"`, // pane 1 proxy
		`src="http://127.0.0.1:8700/"`,            // iframe 0
		`src="http://127.0.0.1:8701/"`,            // iframe 1
		`data-upstream="http://localhost:8788/"`,  // pane 1 upstream
		`id="preview-tab-add"`,                    // runtime add button
	} {
		if !bytes.Contains(body, []byte(want)) {
			t.Errorf("multi-tab preview missing %q in:\n%s", want, string(body[:min(1400, len(body))]))
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
