// claude_test.go — unit tests for parseClaudeStream. We never spawn the
// real `claude` binary here; we feed fixture JSONL into the parser and
// assert the envelope sequence + shapes.
//
// runClaudeTurn (the spawn+glue layer) is covered by the smoke test in the
// task brief — pure unit-testing it would require either a fake `claude`
// binary on PATH or a parallel architecture for injection; both are
// disproportionate for the v0 prototype.
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// captureEmit returns an emit closure plus the slice it appends into.
func captureEmit() (emit func(Envelope), out *[]Envelope) {
	envs := []Envelope{}
	return func(e Envelope) { envs = append(envs, e) }, &envs
}

// fixtureTurnText is a stream-json transcript for a "tiny answer" turn:
// claude thinks briefly and emits one text message ("pong"). No tool calls.
const fixtureTurnText = `{"type":"system","subtype":"init","cwd":"/x","session_id":"s","tools":[],"model":"claude-opus-4-7"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_01","model":"claude-opus-4-7"}}}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"po"}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ng"}}}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"pong"}]}}
{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}
{"type":"stream_event","event":{"type":"message_stop"}}
{"type":"result","subtype":"success","is_error":false,"result":"pong","duration_ms":1234,"total_cost_usd":0.0042}
`

// fixtureTurnToolUse is a richer transcript: thinking block, then a Bash
// tool_use with chunked input_json_delta, then the harness tool_result,
// then a final text reply, then result. Modeled after the sample in the
// task brief.
const fixtureTurnToolUse = `{"type":"system","subtype":"init","cwd":"/x","session_id":"s"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_01"}}}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"thinking","thinking":"let me check","signature":"sig"}]}}
{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"Bash","input":{}}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls -la\""}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":", \"description\":\"List files\"}"}}}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"ls -la","description":"List files"}}]}}
{"type":"stream_event","event":{"type":"content_block_stop","index":1}}
{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"}}}
{"type":"stream_event","event":{"type":"message_stop"}}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"total 0\ndrwxr-xr-x  3 me  staff   96 May 25 03:00 .","is_error":false}]},"tool_use_result":{"stdout":"total 0\ndrwxr-xr-x  3 me  staff   96 May 25 03:00 .","stderr":"","interrupted":false}}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_02"}}}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Here is the answer."}}}
{"type":"assistant","message":{"id":"msg_02","content":[{"type":"text","text":"Here is the answer."}]}}
{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}
{"type":"stream_event","event":{"type":"message_stop"}}
{"type":"result","subtype":"success","is_error":false,"result":"Here is the answer.","duration_ms":4321,"total_cost_usd":0.012}
`

// fixtureTurnError is a transcript that ends with a non-success result.
const fixtureTurnError = `{"type":"system","subtype":"init"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_01"}}}
{"type":"result","subtype":"error_during_execution","is_error":true,"result":"something went wrong","duration_ms":50,"total_cost_usd":0.0}
`

// fixtureToolErrorResult exercises the is_error path in summarizeToolResult.
const fixtureToolErrorResult = `{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_x","name":"Bash","input":{}}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"false\"}"}}}
{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
{"type":"user","message":{"content":[{"tool_use_id":"toolu_x","type":"tool_result","content":"command failed","is_error":true}]},"tool_use_result":{"stdout":"","stderr":"exit status 1","interrupted":false}}
{"type":"result","subtype":"success","is_error":false,"result":"","duration_ms":10,"total_cost_usd":0}
`

func TestParseClaudeStream_CapturesSessionID(t *testing.T) {
	emit, _ := captureEmit()
	// fixtureTurnText's init line carries session_id "s".
	got, err := parseClaudeStream(strings.NewReader(fixtureTurnText), emit)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got != "s" {
		t.Errorf("captured session id = %q, want %q", got, "s")
	}
}

func TestParseClaudeStream_TextOnlyTurn(t *testing.T) {
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(fixtureTurnText), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	types := envTypes(*envs)
	want := []EventType{EventAIThinking, EventAIText, EventTurnComplete}
	if !equalTypes(types, want) {
		t.Fatalf("event sequence:\n got  %v\n want %v", types, want)
	}

	// ai_text payload must be "pong".
	var at AITextData
	if err := json.Unmarshal((*envs)[1].Data, &at); err != nil {
		t.Fatalf("ai_text decode: %v", err)
	}
	if at.Text != "pong" {
		t.Errorf("ai_text=%q want %q", at.Text, "pong")
	}

	// turn_complete must carry cost + duration from the `result` event.
	var tc TurnCompleteData
	if err := json.Unmarshal((*envs)[2].Data, &tc); err != nil {
		t.Fatalf("turn_complete decode: %v", err)
	}
	if tc.DurationMS != 1234 {
		t.Errorf("duration=%d want 1234", tc.DurationMS)
	}
	if tc.CostUSD != 0.0042 {
		t.Errorf("cost=%f want 0.0042", tc.CostUSD)
	}
	if tc.Error != "" {
		t.Errorf("unexpected error: %q", tc.Error)
	}
}

// fixtureTurnNoOutput is a clean (exit-0) turn that produced nothing — no
// ai_text, no tool_call — the agent_no_output class (ARD-0038).
const fixtureTurnNoOutput = `{"type":"system","subtype":"init"}
{"type":"result","subtype":"success","is_error":false,"result":"","duration_ms":5,"total_cost_usd":0}
`

func lastTurnComplete(t *testing.T, envs []Envelope) TurnCompleteData {
	t.Helper()
	for i := len(envs) - 1; i >= 0; i-- {
		if envs[i].Type == EventTurnComplete {
			var tc TurnCompleteData
			if err := json.Unmarshal(envs[i].Data, &tc); err != nil {
				t.Fatalf("turn_complete decode: %v", err)
			}
			return tc
		}
	}
	t.Fatal("no turn_complete envelope")
	return TurnCompleteData{}
}

func TestParseClaudeStream_Verdict(t *testing.T) {
	cases := []struct{ name, fixture, want string }{
		{"text turn", fixtureTurnText, VerdictOK},
		{"tool-use turn", fixtureTurnToolUse, VerdictOK},
		{"error result", fixtureTurnError, VerdictAgentError},
		{"clean but empty", fixtureTurnNoOutput, VerdictAgentNoOutput},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			emit, envs := captureEmit()
			if _, err := parseClaudeStream(strings.NewReader(c.fixture), emit); err != nil {
				t.Fatalf("parse: %v", err)
			}
			if got := lastTurnComplete(t, *envs).Verdict; got != c.want {
				t.Errorf("verdict=%q want %q", got, c.want)
			}
		})
	}
}

func TestParseClaudeStream_ToolUseAndFollowUp(t *testing.T) {
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(fixtureTurnToolUse), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	types := envTypes(*envs)
	// ai_thinking exactly once (only on first message_start), then tool_call,
	// then tool_result, then ai_text for the follow-up message, then complete.
	want := []EventType{
		EventAIThinking,
		EventToolCall,
		EventToolResult,
		EventAIText,
		EventTurnComplete,
	}
	if !equalTypes(types, want) {
		t.Fatalf("event sequence:\n got  %v\n want %v", types, want)
	}

	// tool_call must have the assembled command JSON.
	var tc ToolCallData
	if err := json.Unmarshal((*envs)[1].Data, &tc); err != nil {
		t.Fatalf("tool_call decode: %v", err)
	}
	if tc.Tool != "Bash" {
		t.Errorf("tool=%q want Bash", tc.Tool)
	}
	var args map[string]string
	if err := json.Unmarshal(tc.Args, &args); err != nil {
		t.Fatalf("tool_call.args decode: %v (raw=%s)", err, string(tc.Args))
	}
	if args["command"] != "ls -la" {
		t.Errorf("command=%q want %q", args["command"], "ls -la")
	}
	if args["description"] != "List files" {
		t.Errorf("description=%q want %q", args["description"], "List files")
	}

	// tool_result must surface the stdout in result_summary and recover the
	// tool name from the earlier content_block_start.
	var tr ToolResultData
	if err := json.Unmarshal((*envs)[2].Data, &tr); err != nil {
		t.Fatalf("tool_result decode: %v", err)
	}
	if tr.Tool != "Bash" {
		t.Errorf("tool=%q want Bash", tr.Tool)
	}
	if !strings.Contains(tr.ResultSummary, "total 0") {
		t.Errorf("result_summary missing stdout content: %q", tr.ResultSummary)
	}

	// ai_text must be the final reply.
	var at AITextData
	if err := json.Unmarshal((*envs)[3].Data, &at); err != nil {
		t.Fatalf("ai_text decode: %v", err)
	}
	if at.Text != "Here is the answer." {
		t.Errorf("ai_text=%q", at.Text)
	}
}

func TestParseClaudeStream_ErrorResult(t *testing.T) {
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(fixtureTurnError), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	types := envTypes(*envs)
	want := []EventType{EventAIThinking, EventTurnComplete}
	if !equalTypes(types, want) {
		t.Fatalf("event sequence:\n got  %v\n want %v", types, want)
	}
	var tc TurnCompleteData
	if err := json.Unmarshal((*envs)[1].Data, &tc); err != nil {
		t.Fatalf("turn_complete decode: %v", err)
	}
	if tc.Error == "" {
		t.Errorf("expected turn_complete.error to be set when result.is_error=true")
	}
}

func TestParseClaudeStream_ToolErrorResultSummary(t *testing.T) {
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(fixtureToolErrorResult), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	// Find the tool_result envelope.
	var tr ToolResultData
	found := false
	for _, e := range *envs {
		if e.Type == EventToolResult {
			if err := json.Unmarshal(e.Data, &tr); err != nil {
				t.Fatalf("tool_result decode: %v", err)
			}
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("no tool_result envelope; got %v", envTypes(*envs))
	}
	if !strings.HasPrefix(tr.ResultSummary, "error:") {
		t.Errorf("expected error-prefixed summary; got %q", tr.ResultSummary)
	}
	if !strings.Contains(tr.ResultSummary, "exit status 1") {
		t.Errorf("expected stderr in summary; got %q", tr.ResultSummary)
	}
}

func TestParseClaudeStream_MalformedLineSkipped(t *testing.T) {
	// A malformed line in the middle should not abort parsing.
	in := `{"type":"system","subtype":"init"}
this is not json at all
{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}
{"type":"result","subtype":"success","is_error":false,"result":"ok","duration_ms":1,"total_cost_usd":0}
`
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(in), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	types := envTypes(*envs)
	if !equalTypes(types, []EventType{EventAIThinking, EventTurnComplete}) {
		t.Errorf("malformed line broke parse; got %v", types)
	}
}

func TestParseClaudeStream_EmptyToolInput(t *testing.T) {
	// A tool_use with no input deltas (e.g. a no-arg tool) must still emit
	// a valid tool_call with {} for args, not crash.
	in := `{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_y","name":"NoArgTool","input":{}}}}
{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
{"type":"result","subtype":"success","is_error":false,"result":"","duration_ms":1,"total_cost_usd":0}
`
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(in), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	var tc ToolCallData
	found := false
	for _, e := range *envs {
		if e.Type == EventToolCall {
			if err := json.Unmarshal(e.Data, &tc); err != nil {
				t.Fatalf("tool_call decode: %v", err)
			}
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("no tool_call envelope; got %v", envTypes(*envs))
	}
	if string(tc.Args) != "{}" {
		t.Errorf("expected empty {} args; got %s", string(tc.Args))
	}
	if tc.Tool != "NoArgTool" {
		t.Errorf("tool=%q want NoArgTool", tc.Tool)
	}
}

func TestParseClaudeStream_StopsAtResult(t *testing.T) {
	// Any lines after the `result` event must be ignored (parser returns).
	in := `{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}
{"type":"result","subtype":"success","is_error":false,"result":"done","duration_ms":1,"total_cost_usd":0}
{"type":"stream_event","event":{"type":"content_block_start","index":99,"content_block":{"type":"text","text":""}}}
`
	emit, envs := captureEmit()
	if _, err := parseClaudeStream(strings.NewReader(in), emit); err != nil {
		t.Fatalf("parse: %v", err)
	}
	// Last envelope must be turn_complete; nothing after.
	if len(*envs) == 0 {
		t.Fatalf("no envelopes emitted")
	}
	if last := (*envs)[len(*envs)-1].Type; last != EventTurnComplete {
		t.Errorf("last envelope=%s want %s", last, EventTurnComplete)
	}
}

func TestEmptyMCPConfigFile(t *testing.T) {
	path, err := emptyMCPConfigFile()
	if err != nil {
		t.Fatalf("emptyMCPConfigFile: %v", err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	// claude rejects {} alone — the "mcpServers" key is required even when
	// empty. Lock the exact payload so a refactor can't silently revert.
	want := `{"mcpServers":{}}`
	if string(data) != want {
		t.Errorf("payload=%q want %q", string(data), want)
	}
	// Must be valid JSON; defense against a future stringly-typed refactor.
	var probe map[string]any
	if err := json.Unmarshal(data, &probe); err != nil {
		t.Errorf("not valid JSON: %v", err)
	}
}

func TestAllowedClaudeToolsExcludesOrchestration(t *testing.T) {
	// Pin the allowlist so a well-meaning addition doesn't silently re-admit
	// the orchestration tools we hid because the chat UI has no answer
	// surface for them (AskUserQuestion, Task, SendMessage, etc).
	forbidden := []string{"AskUserQuestion", "Task", "SendMessage", "TaskCreate", "Skill", "EnterPlanMode"}
	allowed := map[string]bool{}
	for _, t := range allowedClaudeTools {
		allowed[t] = true
	}
	for _, name := range forbidden {
		if allowed[name] {
			t.Errorf("orchestration tool %q must not be in allowedClaudeTools", name)
		}
	}
	// And the expected built-ins must still be present.
	for _, name := range []string{"Bash", "Edit", "Read", "Write", "Glob", "Grep", "WebFetch", "WebSearch"} {
		if !allowed[name] {
			t.Errorf("expected built-in tool %q missing from allowedClaudeTools", name)
		}
	}
}

func TestClaudeAvailable_RefusesWithAnthropicAPIKey(t *testing.T) {
	// claudeAvailable checks PATH before ANTHROPIC_API_KEY, so to exercise the
	// key-refusal branch the test must guarantee a `claude` binary is found —
	// otherwise the binary-missing early return fires first. A dev box running
	// Claude Code has claude on PATH (so this passed locally); CI runners don't
	// (so it failed there). Stub one on a temp PATH to make the test hermetic.
	stub := t.TempDir()
	if err := os.WriteFile(filepath.Join(stub, "claude"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", stub+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("ANTHROPIC_API_KEY", "sk-test")

	ok, reason := claudeAvailable()
	if ok {
		t.Fatalf("claudeAvailable should refuse when ANTHROPIC_API_KEY is set")
	}
	if !strings.Contains(strings.ToLower(reason), "anthropic_api_key") {
		t.Errorf("reason should mention ANTHROPIC_API_KEY; got %q", reason)
	}
}

// --- helpers ----------------------------------------------------------------

func envTypes(envs []Envelope) []EventType {
	out := make([]EventType, len(envs))
	for i, e := range envs {
		out[i] = e.Type
	}
	return out
}

func equalTypes(a, b []EventType) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
