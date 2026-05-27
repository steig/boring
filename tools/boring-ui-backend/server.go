// server.go — HTTP routing for the in-container boring-ui backend.
//
// Routes (per ARD-0022 §3 "in-container boring-ui backend"):
//
//	GET  /                  chat UI HTML (embedded assets/index.html)
//	GET  /chat.css          stylesheet
//	GET  /chat.js           client script
//	GET  /api/events        Server-Sent Events stream of envelopes
//	POST /api/messages      {"text": "..."} — triggers a mock turn
//	GET  /api/thread        full thread JSON Lines for hydration
//	POST /api/save          run save flow (shells out to `boring save` or fakes it)
//	GET  /api/save/preview  {"title": "..."} — summarize since last save
//	POST /api/undo          {"event_id": "..."} — stub; emits stub events for v0
//
// The backend listens on a Unix socket (path from --socket flag) and trusts
// the socket boundary as the auth boundary (proxy is upstream auth per
// ARD-0021 §6.1). No CORS, no cookies, no token check inside the container.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"time"
)

//go:embed assets/index.html assets/chat.css assets/chat.js
var assetsFS embed.FS

// Server bundles the long-lived state for one project's backend.
type Server struct {
	Slug         string
	Workdir      string   // project working directory (used by /api/save AND turn spawn)
	PreviewURL   string   // absolute UPSTREAM URL being previewed (per ARD-0022 §6); shown in the header strip + open-in-new-tab link. Empty -> fallback message.
	PreviewFrameURL string // absolute URL the right-pane iframe actually loads: the dedicated-origin preview proxy, e.g. http://127.0.0.1:<port>/ (ARD-0033). Empty even when PreviewURL is set -> fallback (no preview port wired).
	TerminalURL  string   // absolute URL the LEFT-pane iframe loads when set (replaces chat thread w/ embedded terminal, e.g. ttyd serving claude); empty -> SSE chat UI
	Provider     string   // "mock" | "claude" — selects the turn runner in handleMessages
	AllowedPaths []string // resolved workdir-relative glob set for reactive path-allowlist enforcement (ARD-0029 §6 gap #1); empty -> no enforcement
	Broadcaster  *Broadcaster
	Thread       *Thread

	// SaveCmd is the command to shell out to on /api/save. Defaults to
	// "boring save"; tests override. If the binary isn't on PATH, the
	// handler emits a fake save_succeeded event so the v0 UI flow works
	// before lib/saver.sh lands.
	SaveCmd []string

	// TurnRunner overrides the function called to run an AI turn for the
	// "claude" provider. Tests inject a stub here; production code leaves
	// it nil and dispatches to runClaudeTurn. The allowlist parameter
	// carries the resolved AllowedPaths so the runner can perform reactive
	// enforcement after each turn (ARD-0029 §6 gap #1).
	TurnRunner func(ctx context.Context, workdir, prompt string, allowlist []string, bcast *Broadcaster, thread *Thread, sessionID string) error
}

// NewServer constructs a Server with sensible defaults. provider must be
// "mock" or "claude" (main.go validates before reaching here). allowedPaths
// is the parsed --allowed-paths flag value; empty (nil) disables reactive
// enforcement. terminalURL is the embedded-terminal URL for the LEFT pane
// (e.g. ttyd serving claude); empty -> render the SSE chat UI instead.
func NewServer(slug, workdir, previewURL, terminalURL, provider string, allowedPaths []string, b *Broadcaster, t *Thread) *Server {
	return &Server{
		Slug:         slug,
		Workdir:      workdir,
		PreviewURL:   previewURL,
		TerminalURL:  terminalURL,
		Provider:     provider,
		AllowedPaths: allowedPaths,
		Broadcaster:  b,
		Thread:       t,
		SaveCmd:      []string{"boring", "save"},
	}
}

// Handler returns the *http.ServeMux wired up with all routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/events", s.handleEvents)
	mux.HandleFunc("/api/messages", s.handleMessages)
	mux.HandleFunc("/api/thread", s.handleThread)
	mux.HandleFunc("/api/save", s.handleSave)
	mux.HandleFunc("/api/save/preview", s.handleSavePreview)
	mux.HandleFunc("/api/undo", s.handleUndo)

	// NOTE: the preview reverse-proxy is NOT mounted here. As of ARD-0033 it
	// runs on its own dedicated host port (a separate http.Server in main.go,
	// built via newPreviewProxyHandler) so Shopify-style root-absolute asset
	// URLs resolve correctly. This mux only serves the chat UI + its assets.

	// Static assets.
	mux.HandleFunc("/chat.css", s.handleAsset("assets/chat.css", "text/css; charset=utf-8"))
	mux.HandleFunc("/chat.js", s.handleAsset("assets/chat.js", "application/javascript; charset=utf-8"))
	mux.HandleFunc("/", s.handleIndex)

	return mux
}

// --- Asset handlers ---------------------------------------------------------

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowedJSON(w, "GET")
		return
	}
	data, err := fs.ReadFile(assetsFS, "assets/index.html")
	if err != nil {
		http.Error(w, "missing index", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(renderIndex(string(data), s.PreviewURL, s.PreviewFrameURL, s.TerminalURL)))
}

// renderIndex performs serve-time substitution of the pane content.
// The template carries {{PREVIEW_PANE}} (right pane) and {{LEFT_PANE}}
// (left pane: terminal iframe when TerminalURL set, SSE chat UI otherwise).
//
// We don't use html/template because the only dynamic values are CLI flags
// (not user-supplied), and we want the HTML readable in source.
// strings.ReplaceAll is sufficient.
func renderIndex(html, previewURL, previewFrameURL, terminalURL string) string {
	htmlEsc := strings.NewReplacer(`"`, "&quot;", `<`, "&lt;", `>`, "&gt;", `&`, "&amp;")

	// LEFT_PANE: terminal iframe when configured, chat composer + thread otherwise.
	var leftPane string
	if terminalURL != "" {
		safeTerm := htmlEsc.Replace(terminalURL)
		leftPane = `<iframe id="terminal-iframe" src="` + safeTerm +
			`" title="terminal" allow="clipboard-read; clipboard-write"></iframe>`
	} else {
		leftPane = `<div class="thread" id="thread"></div>` +
			`<form class="composer" id="composer" autocomplete="off">` +
			`<input id="input" type="text" placeholder="Ask the AI to change something..." autocomplete="off" />` +
			`<button type="submit" class="btn primary">Send</button>` +
			`</form>`
	}
	html = strings.ReplaceAll(html, "{{LEFT_PANE}}", leftPane)

	// PREVIEW_PANE: the iframe loads the dedicated-origin preview proxy
	// (previewFrameURL, e.g. http://127.0.0.1:<port>/), NOT the upstream
	// directly and NOT a sub-path. See ARD-0033 / preview.go for why.
	//
	// We need BOTH a configured upstream (previewURL) AND a wired preview
	// proxy origin (previewFrameURL). The latter is empty when --preview-port
	// wasn't passed (e.g. a bare `boring-ui-backend --preview-url ...` with no
	// listener) — in that case we degrade to the fallback message rather than
	// render an iframe pointing nowhere.
	var pane string
	if previewURL != "" && previewFrameURL != "" {
		// HTML-attribute-safe escape for URLs inside src="..." / href="...".
		// The URLs come from CLI flags (operator-controlled), so this is
		// defense in depth rather than untrusted-input sanitization.
		htmlEsc := strings.NewReplacer(`"`, "&quot;", `<`, "&lt;", `>`, "&gt;", `&`, "&amp;")
		safeUpstream := htmlEsc.Replace(previewURL)         // header title + open-in-new-tab
		safeFrame := htmlEsc.Replace(previewFrameURL)       // iframe src
		// displayURL is the muted text strip — show the UPSTREAM (what's
		// actually being previewed), scheme-stripped for compactness.
		display := previewURL
		for _, prefix := range []string{"https://", "http://"} {
			if strings.HasPrefix(display, prefix) {
				display = strings.TrimPrefix(display, prefix)
				break
			}
		}
		safeDisplay := htmlEsc.Replace(display)
		// The URL display + open-in-new-tab link use the UPSTREAM URL (so the
		// user sees/opens the real dev server in a clean tab — a top-level tab
		// isn't subject to X-Frame-Options). The IFRAME src is the dedicated
		// preview-proxy origin, which strips the upstream's X-Frame-Options /
		// CSP frame-ancestors so it frames cleanly, and — being served at its
		// own origin root — lets the upstream's root-absolute asset URLs
		// (/cdn/..., /checkouts/...) resolve back into the proxy (ARD-0033).
		pane = `<div class="preview-header">` +
			`<span class="preview-url" title="` + safeUpstream + `">` + safeDisplay + `</span>` +
			`<div class="preview-actions">` +
			`<button type="button" class="preview-btn" id="preview-refresh" title="Reload preview">↻</button>` +
			`<a class="preview-btn" id="preview-open" href="` + safeUpstream + `" target="_blank" rel="noopener noreferrer" title="Open in new tab">↗</a>` +
			`</div>` +
			`</div>` +
			`<iframe id="preview-iframe" src="` + safeFrame + `" title="preview"></iframe>`
	} else {
		pane = `<div id="preview-fallback" class="preview-fallback">` +
			`<p>No preview configured for this project.</p>` +
			`<p class="hint">Set <code>--preview-url</code> on the backend to wire one.</p>` +
			`</div>`
	}
	return strings.ReplaceAll(html, "{{PREVIEW_PANE}}", pane)
}

func (s *Server) handleAsset(name, contentType string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			methodNotAllowedJSON(w, "GET")
			return
		}
		data, err := fs.ReadFile(assetsFS, name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", contentType)
		_, _ = w.Write(data)
	}
}

// --- SSE event stream -------------------------------------------------------

// handleEvents serves the Server-Sent Events stream. Each event is written
// in the standard `event: <type>\ndata: <json>\nid: <id>\n\n` format. The
// connection holds open until the client disconnects or the broadcaster
// closes.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowedJSON(w, "GET")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// Disable nginx-style buffering downstream if any reverse proxy sniffs it.
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	sub := s.Broadcaster.Subscribe()
	defer s.Broadcaster.Unsubscribe(sub)

	// Heartbeat keeps proxies from killing the long-lived connection on
	// idle. 25s is conservative; SSE spec doesn't define a max idle.
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case <-heartbeat.C:
			// SSE comment line (lines starting with ":") — ignored by clients,
			// keeps the socket warm.
			if _, err := fmt.Fprint(w, ": heartbeat\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case env, ok := <-sub:
			if !ok {
				return
			}
			if err := writeSSE(w, env); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// writeSSE writes one envelope to the SSE stream per the spec.
func writeSSE(w http.ResponseWriter, env Envelope) error {
	if _, err := fmt.Fprintf(w, "event: %s\n", env.Type); err != nil {
		return err
	}
	// data: field is the envelope's data payload (NOT the whole envelope).
	// Clients dispatch on the event-name header; they only need the payload.
	if _, err := fmt.Fprintf(w, "data: %s\n", string(env.Data)); err != nil {
		return err
	}
	if env.ID != "" {
		if _, err := fmt.Fprintf(w, "id: %s\n", env.ID); err != nil {
			return err
		}
	}
	_, err := fmt.Fprint(w, "\n")
	return err
}

// --- Message intake ---------------------------------------------------------

type messageReq struct {
	Text string `json:"text"`
}

func (s *Server) handleMessages(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowedJSON(w, "POST")
		return
	}
	var req messageReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid json: "+err.Error())
		return
	}
	if strings.TrimSpace(req.Text) == "" {
		writeJSONError(w, http.StatusBadRequest, "text required")
		return
	}
	// Detach from the request context so the turn finishes even if the
	// client disconnects mid-stream (matches OpenCode/Claude semantics —
	// once a turn starts, we play it to completion and the SSE stream gets
	// the rest on reconnect via hydration).
	turnCtx := context.Background()
	switch s.Provider {
	case "claude":
		runner := s.TurnRunner
		if runner == nil {
			runner = runClaudeTurn
		}
		go func() {
			if err := runner(turnCtx, s.Workdir, req.Text, s.AllowedPaths, s.Broadcaster, s.Thread, s.Slug); err != nil {
				log.Printf("claude turn: %v", err)
			}
		}()
	case "mock":
		fallthrough
	default:
		go (&MockEmitter{Broadcaster: s.Broadcaster, Thread: s.Thread}).
			MockTurn(turnCtx, req.Text)
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"accepted":true}`))
}

// --- Thread hydration -------------------------------------------------------

func (s *Server) handleThread(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowedJSON(w, "GET")
		return
	}
	all, err := s.Thread.ReadAll()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"slug":   s.Slug,
		"events": all,
	}); err != nil {
		log.Printf("thread encode: %v", err)
	}
}

// --- Save flow stub ---------------------------------------------------------

type saveReq struct {
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Draft       bool     `json:"draft"`
	Reviewers   []string `json:"reviewers"`
}

func (s *Server) handleSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowedJSON(w, "POST")
		return
	}
	var req saveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid json: "+err.Error())
		return
	}

	// Emit save_started immediately so the UI can disable input.
	if env, err := s.Broadcaster.NewEnvelope(EventSaveStarted, struct{}{}); err == nil {
		_ = s.Thread.Append(env)
		s.Broadcaster.Publish(env)
	}

	// ACK to the client first — the actual save runs in the background and
	// emits succeeded/failed events via the SSE stream.
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"accepted":true}`))

	go s.runSave(req)
}

// runSave shells out to `boring save` if available; otherwise fakes a
// successful save so the v0 UI flow works end-to-end before lib/saver.sh
// (the other agent's work) lands.
func (s *Server) runSave(req saveReq) {
	// Locate the save binary. If absent, fake it (v0 prototype affordance).
	if len(s.SaveCmd) == 0 {
		s.fakeSaveSucceeded(req)
		return
	}
	if _, err := exec.LookPath(s.SaveCmd[0]); err != nil {
		log.Printf("save: %s not on PATH, faking success: %v", s.SaveCmd[0], err)
		s.fakeSaveSucceeded(req)
		return
	}

	args := append([]string(nil), s.SaveCmd[1:]...)
	args = append(args, "--profile", s.Slug)
	if req.Title != "" {
		args = append(args, "--title", req.Title)
	}
	if req.Description != "" {
		args = append(args, "--description", req.Description)
	}
	if req.Draft {
		args = append(args, "--draft")
	}
	for _, rv := range req.Reviewers {
		args = append(args, "--reviewer", rv)
	}

	cmd := exec.Command(s.SaveCmd[0], args...)
	cmd.Dir = s.Workdir
	out, err := cmd.CombinedOutput()
	if err != nil {
		s.emitSaveFailed(fmt.Sprintf("%s failed: %v\n%s", s.SaveCmd[0], err, string(out)), true)
		return
	}
	// Parse PR URL out of stdout. v0: naive scan for "https://github.com/".
	prURL, branch := parseSaveOutput(string(out))
	if prURL == "" {
		prURL = "https://example.invalid/pr/0" // placeholder when parsing fails
	}
	if branch == "" {
		branch = "marketer/" + s.Slug + "-" + time.Now().UTC().Format("20060102-150405")
	}
	s.emitSaveSucceeded(prURL, branch)
}

// fakeSaveSucceeded emits a synthetic save_succeeded event with a placeholder
// PR URL. Used when the save binary isn't installed (v0 dev affordance).
func (s *Server) fakeSaveSucceeded(req saveReq) {
	branch := "marketer/" + s.Slug + "-" + time.Now().UTC().Format("20060102-150405")
	_ = req
	s.emitSaveSucceeded("https://example.invalid/pr/42", branch)
}

func (s *Server) emitSaveSucceeded(prURL, branch string) {
	env, err := s.Broadcaster.NewEnvelope(EventSaveSucceeded, SaveSucceededData{
		PRURL: prURL, BranchName: branch,
	})
	if err != nil {
		log.Printf("save_succeeded envelope: %v", err)
		return
	}
	_ = s.Thread.Append(env)
	s.Broadcaster.Publish(env)
}

func (s *Server) emitSaveFailed(msg string, recoverable bool) {
	env, err := s.Broadcaster.NewEnvelope(EventSaveFailed, SaveFailedData{
		Error: msg, Recoverable: recoverable,
	})
	if err != nil {
		log.Printf("save_failed envelope: %v", err)
		return
	}
	_ = s.Thread.Append(env)
	s.Broadcaster.Publish(env)
}

// parseSaveOutput scans `boring save` output for a GitHub PR URL and branch
// name. v0 best-effort; the real wire format will be JSON once the other
// agent lands lib/saver.sh.
func parseSaveOutput(out string) (prURL, branch string) {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if prURL == "" && strings.Contains(line, "https://github.com/") {
			// First token containing the URL substring.
			for _, tok := range strings.Fields(line) {
				if strings.HasPrefix(tok, "https://github.com/") {
					prURL = tok
					break
				}
			}
		}
		// Naive branch-name extraction: lines like "branch: marketer/..." .
		if strings.HasPrefix(line, "branch:") {
			branch = strings.TrimSpace(strings.TrimPrefix(line, "branch:"))
		}
	}
	return prURL, branch
}

// handleSavePreview returns the AI-summarized title the save dialog should
// pre-fill. v0: deterministic summary; real call to OpenCode for an AI
// title comes later.
func (s *Server) handleSavePreview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowedJSON(w, "GET")
		return
	}
	title, err := s.Thread.SummarizeSinceLastSave()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"title":       title,
		"description": "Generated from boring-ui chat thread.",
	})
}

// --- Undo stub --------------------------------------------------------------

type undoReq struct {
	EventID string `json:"event_id"`
}

func (s *Server) handleUndo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowedJSON(w, "POST")
		return
	}
	var req undoReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid json: "+err.Error())
		return
	}
	// v0 stub: emit a synthetic tool_result event marking the undo.
	// Real implementation does `git revert <commit>` per ARD-0022 §4.
	env, err := s.Broadcaster.NewEnvelope(EventToolResult, ToolResultData{
		Tool:          "undo",
		ResultSummary: "Undid event " + req.EventID + " (stub; git revert not wired in v0)",
	})
	if err == nil {
		_ = s.Thread.Append(env)
		s.Broadcaster.Publish(env)
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"accepted":true}`))
}

// --- Helpers ----------------------------------------------------------------

func methodNotAllowedJSON(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusMethodNotAllowed)
	_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
}

func writeJSONError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
