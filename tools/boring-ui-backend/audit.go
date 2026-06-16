// audit.go — best-effort bridge from backend-originated events to the ARD-0010
// audit FIFO. The EmitAudit obligation of ARD-0037's contract.
//
// Scope is deliberately narrow and honest. For the claude provider, the
// prompt / tool / completion audit trail is already captured by Claude Code's
// native hooks (UserPromptSubmit / PostToolUse / Stop in settings.json, which
// shell out to audit-emit-<kind> — ARD-0010 §3). The backend must NOT
// re-emit those or every claude turn double-logs.
//
// What no hook covers is the events the backend itself originates — chiefly
// policy_blocked, the path-gate's post-turn reverts (policy.go). That is an
// ARD-0010 security event (kind guardrail_violation) with no other route to
// the audit log. This file carries exactly those to the FIFO.
//
// The envelope matches templates/_common/boring-bin/audit-emit byte-for-byte
// (ts/kind/profile/user/details) plus the agent field (ARD-0027) so
// `boring audit --agent` can filter by harness. The collector
// (lib/audit.sh audit_route_for) routes on kind alone, so the extra field
// rides through into the JSONL untouched.
package main

import (
	"encoding/json"
	"os"
	"syscall"
	"time"
)

// auditFIFOPath is the in-container write end of the ARD-0010 audit FIFO,
// bind-mounted by lib/compose.sh. A package var so tests can point it at a
// temp FIFO.
var auditFIFOPath = "/var/log/boring/events.fifo"

// auditEvent is the JSONL envelope the collector consumes.
type auditEvent struct {
	TS      string `json:"ts"`
	Kind    string `json:"kind"`
	Profile string `json:"profile"`
	User    string `json:"user"`
	Agent   string `json:"agent"`
	Details any    `json:"details"`
}

// emitAudit writes one event to the audit FIFO, best-effort. A missing FIFO or
// an absent collector (no reader) is the normal case when audit isn't wired for
// this profile; we skip silently rather than fail the turn — ARD-0010's rule
// that a dropped audit event must never block real behavior, matching
// audit-emit's trailing `|| true`.
func emitAudit(kind, agent string, details any) {
	ev := auditEvent{
		TS:      time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		Kind:    kind,
		Profile: envOr("BORING_PROFILE_NAME", "unknown"),
		User:    envOr("BORING_HOST_USER", envOr("USER", "unknown")),
		Agent:   agent,
		Details: details,
	}
	line, err := json.Marshal(ev)
	if err != nil {
		return
	}
	// O_NONBLOCK write-open: on a FIFO with no reader this returns ENXIO —
	// exactly the "collector down" case we skip. With a reader it succeeds; the
	// line is under PIPE_BUF so the Write is atomic, though a full pipe buffer
	// (slow collector) drops it via EAGAIN — acceptable for best-effort audit.
	f, err := os.OpenFile(auditFIFOPath, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
