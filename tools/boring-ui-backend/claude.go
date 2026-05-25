// claude.go — Claude Code subscription provider for boring-ui-backend.
//
// Spawns the real `claude` CLI per turn with stream-json output, parses the
// event stream line-by-line, and maps each upstream event to our envelope
// shape (events.go). This is the v0 path that bypasses OpenCode entirely —
// it preserves Claude Max subscription billing because it shells out to the
// same `claude` binary the user already authenticated.
//
// Spawn command:
//
//	claude --print --output-format=stream-json \
//	       --include-partial-messages --no-session-persistence --verbose
//
// stdin = the user's prompt. stdout = JSONL stream-json events. The wrapper
// parses each line and emits envelopes onto the broadcaster + thread; the
// chat UI subscribes via SSE (server.go) and renders cards.
//
// Mapping rules (see parseClaudeStream for the implementation):
//
//   - First `stream_event.message_start` of the turn      → ai_thinking
//   - `content_block_start` with type=tool_use            → start tool buffer
//   - `content_block_delta` with type=input_json_delta    → append partial JSON
//   - `content_block_stop` for a tool_use block           → emit tool_call
//   - `assistant` message with text content blocks        → emit ai_text per block
//   - `user` message with tool_result content blocks      → emit tool_result
//   - `result` (any subtype)                              → emit turn_complete; stop
//
// We rely on `content_block_stop` (with our accumulated tool input JSON) to
// emit tool_call rather than the final assistant message — that way the UI
// sees the tool call BEFORE the tool_result arrives, even though the
// assistant-message line lands after content_block_stop in the stream.
//
// Subscription guard: claudeAvailable() refuses to run with ANTHROPIC_API_KEY
// set, which would bypass the user's Claude Max subscription billing.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// claudeAvailable returns true if the real `claude` binary is on PATH and
// the user does NOT have ANTHROPIC_API_KEY set. The env-var check is the
// subscription guard: with ANTHROPIC_API_KEY in the environment, claude
// bills against the API key rather than the user's Claude Max subscription,
// which would defeat ARD-0020's intent. Refuse to run rather than silently
// over-bill.
func claudeAvailable() (bool, string) {
	if _, err := exec.LookPath("claude"); err != nil {
		return false, "claude binary not on PATH"
	}
	if os.Getenv("ANTHROPIC_API_KEY") != "" {
		return false, "ANTHROPIC_API_KEY is set; refusing to run --provider claude (would bypass Claude Max subscription billing per ARD-0020). Unset the env var or use --provider mock."
	}
	return true, ""
}

// ClaudeEmitter ties broadcaster + thread together. Mirrors mock.go's
// MockEmitter so emit-and-persist is identical to the mock path.
type claudeEmitter struct {
	bcast  *Broadcaster
	thread *Thread
}

func (e *claudeEmitter) emit(t EventType, data any) {
	env, err := e.bcast.NewEnvelope(t, data)
	if err != nil {
		log.Printf("claude: envelope build (%s): %v", t, err)
		return
	}
	if err := e.thread.Append(env); err != nil {
		log.Printf("claude: thread append (%s): %v", t, err)
	}
	e.bcast.Publish(env)
}

// emptyMCPConfigFile writes a temporary JSON file containing the minimal
// {"mcpServers":{}} payload claude requires when combined with
// --strict-mcp-config to suppress every MCP server. /dev/null is rejected
// by claude's MCP validator ("Invalid MCP configuration"), so we materialize
// a real file. Caller is responsible for removing the path when done.
//
// Returns ("", err) if the tempfile can't be created; the caller should
// log + skip the flag pair rather than fail the turn outright.
func emptyMCPConfigFile() (string, error) {
	f, err := os.CreateTemp("", "boring-ui-mcp-empty-*.json")
	if err != nil {
		return "", fmt.Errorf("create mcp tempfile: %w", err)
	}
	if _, err := f.WriteString(`{"mcpServers":{}}`); err != nil {
		_ = f.Close()
		_ = os.Remove(f.Name())
		return "", fmt.Errorf("write mcp tempfile: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(f.Name())
		return "", fmt.Errorf("close mcp tempfile: %w", err)
	}
	return f.Name(), nil
}

// allowedClaudeTools is the built-in tool allowlist passed via --allowed-tools.
// These are the tools that have a sensible affordance in the boring-ui chat:
// file editing, shell, search, web. Orchestration tools (Task, AskUserQuestion,
// SendMessage, TaskCreate, etc.) are excluded because the chat UI has no
// answer surface for them — they'd render as dead-end cards.
//
// Defense in depth: even with these excluded server-side, chat.js renders any
// stray tool calls via a generic fallback rather than dropping them, so the
// user can still see if something slips through.
var allowedClaudeTools = []string{
	"Bash", "Edit", "Read", "Write", "Glob", "Grep", "WebFetch", "WebSearch",
}

// runClaudeTurn spawns the claude CLI with the given prompt and streams its
// events into the broadcaster + thread. Returns when claude exits or ctx is
// cancelled. The sessionID is currently unused (--no-session-persistence is
// always set in v0); it's accepted as a parameter so the call-site is ready
// for the future "resume the same conversation" capability.
//
// Hardening flags (added 2026-05-25 to fix the "raw MCP/orchestration tool
// cards" UX problem):
//
//   - --strict-mcp-config + --mcp-config <tmpfile {"mcpServers":{}}>: suppress
//     every MCP server the user has configured (brain-cloud, Gmail, Calendar,
//     Drive — none belong in a marketer's chat). /dev/null is rejected by
//     claude, so we materialize a real empty config.
//   - --allowed-tools "Bash Edit Read Write Glob Grep WebFetch WebSearch":
//     explicit allowlist of built-in tools with a chat affordance. Excludes
//     AskUserQuestion, Task, SendMessage, TaskCreate, etc.
//
// We deliberately do NOT pass --bare. --bare requires the caller to provide
// system-prompt context explicitly (--system-prompt[-file] or
// --append-system-prompt[-file]) and skips CLAUDE.md auto-discovery, which
// would break the project-context expectation for marketers' chats. The two
// flags above already eliminate the user-reported leakage (personal MCPs +
// orchestration tools) without nuking the system prompt.
func runClaudeTurn(ctx context.Context, workdir, prompt string, bcast *Broadcaster, thread *Thread, sessionID string) error {
	_ = sessionID // reserved; --no-session-persistence is always set in v0.

	emit := &claudeEmitter{bcast: bcast, thread: thread}

	// Echo the user message immediately so the UI shows it before claude
	// even starts. Matches the mock path's behavior.
	emit.emit(EventUserMessage, UserMessageData{Text: prompt})

	// Build the argv. The MCP tempfile is best-effort: if we can't create it,
	// we log + drop both --strict-mcp-config and --mcp-config and let claude
	// fall through to its default MCP discovery. Users can still see any
	// stray MCP cards via chat.js's generic-fallback renderer.
	args := []string{
		"--print",
		"--output-format=stream-json",
		"--include-partial-messages",
		"--no-session-persistence",
		"--verbose",
		"--allowed-tools", strings.Join(allowedClaudeTools, " "),
	}
	mcpCfg, mcpErr := emptyMCPConfigFile()
	if mcpErr != nil {
		log.Printf("claude: empty MCP config: %v (skipping --strict-mcp-config; user MCPs may leak into chat)", mcpErr)
	} else {
		defer os.Remove(mcpCfg)
		args = append(args, "--strict-mcp-config", "--mcp-config", mcpCfg)
	}

	cmd := exec.CommandContext(ctx, "claude", args...)
	cmd.Dir = workdir
	// Inherit env (claude needs HOME, PATH, the subscription credentials in
	// ~/.claude/, etc). The ANTHROPIC_API_KEY refusal happens in
	// claudeAvailable() at startup, not here — by the time we reach this
	// function the caller already confirmed it's safe to run.
	cmd.Env = os.Environ()
	// Put the child in its own process group so we can kill the whole tree
	// on ctx cancellation (claude may spawn helpers).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		emit.emit(EventTurnComplete, TurnCompleteData{Error: "stdin pipe: " + err.Error()})
		return fmt.Errorf("claude: stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		emit.emit(EventTurnComplete, TurnCompleteData{Error: "stdout pipe: " + err.Error()})
		return fmt.Errorf("claude: stdout pipe: %w", err)
	}
	// Capture stderr to a buffer so we can include it in error reporting
	// without polluting the SSE stream.
	var stderrBuf strings.Builder
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		emit.emit(EventTurnComplete, TurnCompleteData{Error: "spawn: " + err.Error()})
		return fmt.Errorf("claude: start: %w", err)
	}

	// Write the prompt + close stdin so claude knows the input is finished.
	go func() {
		_, _ = io.WriteString(stdin, prompt)
		_ = stdin.Close()
	}()

	// Track whether the parser saw a `result` event (which emits its own
	// turn_complete). If claude exits without one — crash, kill, etc — we
	// emit a turn_complete with the error so the UI un-busies the composer.
	sawResult := false

	// Wrap emit to re-stamp envelopes through the real broadcaster so IDs
	// share the same monotonic sequence as the user_message we already
	// emitted. Without this, parser-built envelopes restart at evt-1 and
	// collide with the outer sequence.
	parseErr := parseClaudeStream(stdout, func(env Envelope) {
		if env.Type == EventTurnComplete {
			sawResult = true
		}
		restamped, err := bcast.NewEnvelope(env.Type, json.RawMessage(env.Data))
		if err != nil {
			log.Printf("claude: re-envelope (%s): %v", env.Type, err)
			return
		}
		if err := thread.Append(restamped); err != nil {
			log.Printf("claude: thread append (%s): %v", restamped.Type, err)
		}
		bcast.Publish(restamped)
	})

	waitErr := cmd.Wait()
	if waitErr != nil && !sawResult {
		// Process died without a `result` event — kill the whole pgrp in
		// case anything is lingering, then synthesize turn_complete so the
		// UI doesn't spin forever.
		_ = killGroup(cmd)
		stderrTail := tailString(stderrBuf.String(), 400)
		msg := fmt.Sprintf("claude exited: %v; stderr: %s", waitErr, stderrTail)
		emit.emit(EventTurnComplete, TurnCompleteData{Error: msg})
		if errors.Is(ctx.Err(), context.Canceled) {
			return ctx.Err()
		}
		return fmt.Errorf("claude: %w (stderr: %s)", waitErr, stderrTail)
	}
	if parseErr != nil && !sawResult {
		emit.emit(EventTurnComplete, TurnCompleteData{Error: "parse: " + parseErr.Error()})
		return fmt.Errorf("claude: parse: %w", parseErr)
	}
	return nil
}

// killGroup best-effort kills the child's process group. Helpers spawned by
// claude (e.g. hook scripts) would otherwise stick around.
func killGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	// Negative pid → signal the entire process group.
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
}

// tailString returns the last n bytes of s (or all of it if shorter).
func tailString(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return "..." + s[len(s)-n:]
}

// --- Stream parser ----------------------------------------------------------

// streamLine is the discriminator for claude's stream-json output. Only the
// fields we care about are declared; everything else is ignored on decode.
type streamLine struct {
	Type    string          `json:"type"`
	Subtype string          `json:"subtype,omitempty"`
	Event   json.RawMessage `json:"event,omitempty"`
	Message json.RawMessage `json:"message,omitempty"`

	// Result-only fields.
	IsError    bool            `json:"is_error,omitempty"`
	Result     string          `json:"result,omitempty"`
	DurationMS int64           `json:"duration_ms,omitempty"`
	TotalCost  float64         `json:"total_cost_usd,omitempty"`
	ToolResult json.RawMessage `json:"tool_use_result,omitempty"`
}

// streamEvent is the inner Anthropic SDK event shape (claude wraps these
// in a stream_event envelope). We only model the fields we need.
type streamEvent struct {
	Type         string `json:"type"`
	Index        int    `json:"index,omitempty"`
	ContentBlock struct {
		Type  string          `json:"type"`
		ID    string          `json:"id,omitempty"`
		Name  string          `json:"name,omitempty"`
		Input json.RawMessage `json:"input,omitempty"`
		Text  string          `json:"text,omitempty"`
	} `json:"content_block,omitempty"`
	Delta struct {
		Type        string `json:"type,omitempty"`
		Text        string `json:"text,omitempty"`
		PartialJSON string `json:"partial_json,omitempty"`
		StopReason  string `json:"stop_reason,omitempty"`
	} `json:"delta,omitempty"`
}

// assistantMessage models the `assistant` line. content[] is a mix of
// thinking / text / tool_use blocks; we read text + tool_use.
type assistantMessage struct {
	Message struct {
		Content []struct {
			Type  string          `json:"type"`
			Text  string          `json:"text,omitempty"`
			ID    string          `json:"id,omitempty"`
			Name  string          `json:"name,omitempty"`
			Input json.RawMessage `json:"input,omitempty"`
		} `json:"content"`
	} `json:"message"`
}

// userMessage models the `user` line that carries tool_result content. We
// also surface tool_use_result.stdout for synthesizing the result_summary.
type userMessage struct {
	Message struct {
		Content []struct {
			Type      string          `json:"type"`
			ToolUseID string          `json:"tool_use_id,omitempty"`
			Content   json.RawMessage `json:"content,omitempty"`
			IsError   bool            `json:"is_error,omitempty"`
		} `json:"content"`
	} `json:"message"`
	ToolUseResult struct {
		Stdout      string `json:"stdout,omitempty"`
		Stderr      string `json:"stderr,omitempty"`
		Interrupted bool   `json:"interrupted,omitempty"`
	} `json:"tool_use_result"`
}

// blockAccum holds the in-progress state for a single content block, keyed
// by stream-event index. The index resets at each new message_start, so we
// reset the map on message_start too.
type blockAccum struct {
	blockType string // "thinking" | "text" | "tool_use"

	// Tool-use specifics.
	toolName  string
	toolID    string
	toolInput strings.Builder
}

// parseClaudeStream reads JSONL from r and emits envelopes via emit. Returns
// nil on clean EOF, an error on scanner failure. emit is called for every
// envelope the parser builds; the caller is responsible for the broadcaster
// + thread side effects.
//
// This function is the seam for testing: feed in fixture JSONL, capture
// the envelopes, assert the sequence + shapes. runClaudeTurn glues this to
// the spawn + emit-and-persist.
func parseClaudeStream(r io.Reader, emit func(Envelope)) error {
	// Helper for building envelopes outside the broadcaster (the parser is
	// pure — the caller in runClaudeTurn re-stamps IDs via thread/broadcast
	// when it actually publishes, but for unit testing we want envelopes
	// with stable shapes too). We build a tiny local broadcaster just to
	// reuse NewEnvelope.
	local := NewBroadcaster()
	defer local.Close()

	scanner := bufio.NewScanner(r)
	// stream-json lines can be large (multi-MB assistant messages with
	// embedded thinking + tool inputs). Bump the scan buffer accordingly.
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)

	blocks := map[int]*blockAccum{}  // index → accumulator
	toolNames := map[string]string{} // tool_use_id → tool name (persists across blocks)
	thinkingEmitted := false

	emitEnv := func(t EventType, data any) {
		env, err := local.NewEnvelope(t, data)
		if err != nil {
			log.Printf("claude parse: envelope (%s): %v", t, err)
			return
		}
		emit(env)
	}

	for scanner.Scan() {
		raw := strings.TrimSpace(scanner.Text())
		if raw == "" {
			continue
		}
		var line streamLine
		if err := json.Unmarshal([]byte(raw), &line); err != nil {
			log.Printf("claude parse: skipping malformed line: %v", err)
			continue
		}

		switch line.Type {

		case "system":
			// init / status / hook events: ignore. They're protocol-level
			// chatter that the chat UI doesn't render in v0.

		case "stream_event":
			var ev streamEvent
			if err := json.Unmarshal(line.Event, &ev); err != nil {
				log.Printf("claude parse: stream_event decode: %v", err)
				continue
			}
			switch ev.Type {
			case "message_start":
				// New assistant message in this turn. Reset block accumulator
				// (block indexes restart per message). Emit ai_thinking on
				// the FIRST message_start only — subsequent ones (after a
				// tool_use loop) are already past the "thinking" UX.
				blocks = map[int]*blockAccum{}
				if !thinkingEmitted {
					emitEnv(EventAIThinking, struct{}{})
					thinkingEmitted = true
				}

			case "content_block_start":
				blocks[ev.Index] = &blockAccum{
					blockType: ev.ContentBlock.Type,
					toolName:  ev.ContentBlock.Name,
					toolID:    ev.ContentBlock.ID,
				}
				if ev.ContentBlock.Type == "tool_use" && ev.ContentBlock.ID != "" {
					toolNames[ev.ContentBlock.ID] = ev.ContentBlock.Name
				}

			case "content_block_delta":
				acc := blocks[ev.Index]
				if acc == nil {
					// Delta for a block we never saw start — skip rather
					// than guess.
					continue
				}
				if ev.Delta.Type == "input_json_delta" && acc.blockType == "tool_use" {
					acc.toolInput.WriteString(ev.Delta.PartialJSON)
				}
				// text_delta / signature_delta / thinking_delta: we don't
				// stream partial text in v0; we wait for the full
				// `assistant` line. Drop here.

			case "content_block_stop":
				acc := blocks[ev.Index]
				if acc == nil {
					continue
				}
				if acc.blockType == "tool_use" {
					// Emit tool_call with the accumulated input. If the
					// accumulator is empty (no deltas — input arrived
					// inline on content_block_start), use {}.
					inputRaw := acc.toolInput.String()
					if inputRaw == "" {
						inputRaw = "{}"
					}
					// Validate the JSON; if it's malformed, fall back to a
					// string representation so the UI still gets the call.
					if !json.Valid([]byte(inputRaw)) {
						b, _ := json.Marshal(inputRaw)
						inputRaw = string(b)
					}
					emitEnv(EventToolCall, ToolCallData{
						Tool: acc.toolName,
						Args: json.RawMessage(inputRaw),
					})
				}
				// Text blocks: defer to the `assistant` line which carries
				// the full text. Drop here.
				delete(blocks, ev.Index)

			case "message_delta", "message_stop":
				// Per-message housekeeping — no UI affordance in v0.

			default:
				// Unknown stream_event sub-type: ignore.
			}

		case "assistant":
			// The full assistant message lands here AFTER its content_block_*
			// events. Pick out text blocks and emit one ai_text per block.
			var am assistantMessage
			if err := json.Unmarshal([]byte(raw), &am); err != nil {
				log.Printf("claude parse: assistant decode: %v", err)
				continue
			}
			for _, c := range am.Message.Content {
				if c.Type == "text" && strings.TrimSpace(c.Text) != "" {
					emitEnv(EventAIText, AITextData{Text: c.Text})
				}
				// thinking / tool_use blocks: already handled via the
				// stream_event path. We could fall back here if streaming
				// was off (--include-partial-messages absent), but v0
				// always sets that flag.
			}

		case "user":
			// User-role messages in this stream come from the harness
			// itself — they carry tool_result content blocks reporting
			// what each tool did. Emit one tool_result per content block.
			var um userMessage
			if err := json.Unmarshal([]byte(raw), &um); err != nil {
				log.Printf("claude parse: user decode: %v", err)
				continue
			}
			for _, c := range um.Message.Content {
				if c.Type != "tool_result" {
					continue
				}
				summary := summarizeToolResult(c.Content, c.IsError, um.ToolUseResult.Stdout, um.ToolUseResult.Stderr)
				tool := toolNames[c.ToolUseID]
				if tool == "" {
					tool = "tool"
				}
				emitEnv(EventToolResult, ToolResultData{
					Tool:          tool,
					ResultSummary: summary,
					// v0: no diff synthesis. ARD-0022 §4.2 envisages diffs
					// for file_edit, but that needs tool-aware extraction.
				})
			}

		case "result":
			// Turn end. Emit turn_complete with cost/duration; subtype
			// "success" → no error, other subtypes → set error.
			td := TurnCompleteData{
				CostUSD:    line.TotalCost,
				DurationMS: line.DurationMS,
			}
			if line.IsError || (line.Subtype != "" && line.Subtype != "success") {
				if line.Result != "" {
					td.Error = line.Result
				} else {
					td.Error = "claude reported error (subtype=" + line.Subtype + ")"
				}
			}
			emitEnv(EventTurnComplete, td)
			// `result` is the documented turn terminator. Stop reading; the
			// caller will reap the process via Wait().
			return nil

		case "rate_limit_event":
			// Informational; could surface as a toast later. v0: ignore.

		default:
			// Unknown top-level type — log + skip rather than fail.
			log.Printf("claude parse: ignoring unknown type %q", line.Type)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan: %w", err)
	}
	return nil
}

// summarizeToolResult builds the result_summary string from the inner
// content payload + the harness-side tool_use_result.{stdout,stderr}.
//
// Strategy (v0, simple):
//   - If is_error: prefix "error: " + take stderr (or content) first 200c.
//   - Else if stdout present: first 200 chars of stdout.
//   - Else: best-effort string from content payload, first 200 chars.
//   - Empty → "completed".
func summarizeToolResult(content json.RawMessage, isError bool, stdout, stderr string) string {
	const max = 200
	pick := func(s string) string {
		s = strings.TrimSpace(s)
		if len(s) > max {
			s = s[:max] + "…"
		}
		return s
	}
	if isError {
		if stderr != "" {
			return "error: " + pick(stderr)
		}
		if raw := contentToString(content); raw != "" {
			return "error: " + pick(raw)
		}
		return "error"
	}
	if stdout != "" {
		return pick(stdout)
	}
	if raw := contentToString(content); raw != "" {
		return pick(raw)
	}
	return "completed"
}

// contentToString unwraps a tool_result content payload (which can be a
// plain string or an array of {type, text} blocks per Anthropic SDK shape)
// into a flat string for summary purposes.
func contentToString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	// Try string first.
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	// Try array of {type:"text", text:"..."}.
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &blocks); err == nil {
		var sb strings.Builder
		for _, b := range blocks {
			if b.Type == "text" {
				sb.WriteString(b.Text)
			}
		}
		return sb.String()
	}
	return string(raw) // last resort: the raw JSON bytes.
}
