// provider.go — the AgentProvider contract (ARD-0037).
//
// One agent harness = one AgentProvider. The contract is sandcastle's provider
// shape (build a turn command, parse the stream into our envelopes, own session
// continuity) inverted to thread boring's trust anchor THROUGH each harness
// rather than bypass it: RunTurn carries the resolved guardrails (TurnSpec), and
// each impl owns its path-gate + audit obligations (ARD-0037 §1, §4).
//
// claudeProvider is the v0 implementation (wraps runClaudeTurn / parseClaudeStream
// in claude.go). mockProvider stands in for the deferred OpenCode harness
// (ARD-0020). opencode slots in as a third case here when its subscription
// precondition clears — without touching the dispatch site or the frontend.
package main

import (
	"context"
	"sync"
)

// TurnSpec is the resolved, per-turn input an AgentProvider needs. It carries
// the guardrails boring threads through the harness (ARD-0037 §1): the tool
// allowlist and path allowlist the provider enforces natively. Session
// continuity is the provider's own concern (claudeProvider holds the captured
// claude session id across turns), so it is not a TurnSpec field.
type TurnSpec struct {
	Workdir      string
	Prompt       string
	Allowlist    []string // resolved workdir-relative globs; empty -> no path enforcement
	AllowedTools []string // resolved tool allowlist, already translated for this harness; empty -> provider default
}

// AgentProvider drives one agent harness within boring's trust anchor.
// RunTurn blocks until the turn ends or ctx is cancelled, emitting envelopes
// onto the broadcaster + thread (events.go) as it goes.
//
// The path-gate obligation (ARD-0037 §1's GateToolCall) lives inside RunTurn,
// not as a separate per-call member: a synchronous per-call gate is impossible
// for harnesses like `claude --print` where tool calls fire inside the agent
// before we observe them in the stream. Each impl is responsible for enforcing
// spec.Allowlist and documents how completely it does so (the §2 completeness
// seam):
//   - claudeProvider: REACTIVE — after the turn, out-of-allowlist writes are
//     reverted via git and a policy_blocked event is emitted (policy.go). Real
//     but post-hoc; a write lands then is undone.
//   - opencode (future): PROACTIVE — an in-process pre-exec hook rejects the
//     call before it forwards to the real tool.
type AgentProvider interface {
	// Name is the registry key — the --provider value this impl answers to.
	Name() string
	// RunTurn executes one turn to completion, enforcing spec.Allowlist per
	// the provider's documented gate completeness.
	RunTurn(ctx context.Context, spec TurnSpec, bcast *Broadcaster, thread *Thread) error
}

// newProvider resolves a --provider name to its AgentProvider. Unknown names
// fall through to mock (preserving the old dispatch switch); main.go rejects
// them at startup before the server is built.
func newProvider(name string) AgentProvider {
	switch name {
	case "claude":
		return &claudeProvider{}
	default:
		return mockProvider{}
	}
}

// claudeProvider is the Claude Code subscription harness (claude.go). It holds
// the captured claude session id across turns so each turn --resumes the same
// conversation — boring-ui's one-thread-per-project model (ARD-0022). The mutex
// keeps the field data-race-free; turn serialization (no two turns at once) is
// the UI's job (composer disabled mid-turn).
type claudeProvider struct {
	mu      sync.Mutex
	session string
}

// claudeAgentName is the registry key + the audit `agent:` value for the
// claude harness — one source so claude.go's audit events agree with dispatch.
const claudeAgentName = "claude"

func (*claudeProvider) Name() string { return claudeAgentName }

func (p *claudeProvider) RunTurn(ctx context.Context, spec TurnSpec, bcast *Broadcaster, thread *Thread) error {
	p.mu.Lock()
	resumeID := p.session
	p.mu.Unlock()

	newID, err := runClaudeTurn(ctx, spec, resumeID, bcast, thread)
	if newID != "" {
		p.mu.Lock()
		p.session = newID
		p.mu.Unlock()
	}
	return err
}

// mockProvider is the deterministic fixture generator (mock.go) standing in for
// OpenCode until ARD-0020's subscription verification lights up the real harness.
type mockProvider struct{}

func (mockProvider) Name() string { return "mock" }

func (mockProvider) RunTurn(ctx context.Context, spec TurnSpec, bcast *Broadcaster, thread *Thread) error {
	(&MockEmitter{Broadcaster: bcast, Thread: thread}).MockTurn(ctx, spec.Prompt)
	return nil
}
