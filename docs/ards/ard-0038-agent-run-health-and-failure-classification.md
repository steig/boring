# ARD-0038: Agent-run health verification + failure classification

- **Status:** Proposed
- **Date:** 2026-06-07
- **Deciders:** Tom (Claude facilitating)
- **Prompted by:** audit of [`tastyeffectco/sandboxes`](https://github.com/tastyeffectco/sandboxes) (2026-06-07). Its `runtimed` harness learned that OpenCode (and Claude) often **exit 0 having produced nothing** — auth hiccup, refusal, empty result — and classifies "exit 0 with zero text and zero tool events," plus any structured `error` event, as a **failure regardless of exit code**. It also runs a post-task pipeline (`checkpoint → agent_running → build_check → health_check`) that probes **live entry assets** and reports a "preview error" when the app is blank despite a clean build — catching the failure class a `tsc`/build pass misses.
- **Extends:** [ARD-0013](ard-0013-headless-boring-run.md) (the `boring run` contract is exit-code-only today; the agent-no-output class slips through), [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) / [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) (the `turn_complete` envelope gains a verdict), [ARD-0035](ard-0035-preview-tabs-and-editable-address-bar.md) / [ARD-0033](ard-0033-preview-iframe-on-dedicated-origin.md) (the dedicated-origin preview proxy is the probe surface).
- **Related:** [[ard-0010-audit-log-and-prompt-tracing-infrastructure]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0030-dev-profile-field-foreground-command-on-boring-open]], [[ard-0037-agent-harness-provider-contract]]

## Context

`boring run` ([ARD-0013](ard-0013-headless-boring-run.md) §2) maps success/failure to Claude's exit code: *"0 on Claude success, non-zero on failure."* boring-ui ([ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md)) emits `turn_complete{cost_usd, duration_ms, error?}` where `error` tracks the stream's terminal `result`.

Both inherit the failure mode `sandboxes` hit head-on: **the agent CLI exits 0 having done nothing useful.** This is not hypothetical for boring — [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) names OpenCode as the target harness, and OpenCode is the **exact CLI** `sandboxes` caught doing this (it "often exits 0 even after an auth failure"). Relying on exit code means a CI `boring run` ([ARD-0013](ard-0013-headless-boring-run.md)) or a marketer turn ([ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md)) reports **success on an empty result**.

Separately, for the web-app dev loop (`dev:` foreground — [ARD-0030](ard-0030-dev-profile-field-foreground-command-on-boring-open.md) — plus the [ARD-0035](ard-0035-preview-tabs-and-editable-address-bar.md) preview tabs), a "clean build, blank page" outcome is invisible to a build-only check. `sandboxes` built a live-asset probe for exactly this; boring already has the dedicated-origin proxy ([ARD-0033](ard-0033-preview-iframe-on-dedicated-origin.md)/[ARD-0035](ard-0035-preview-tabs-and-editable-address-bar.md)) to probe through — `sandboxes` had to stand up Traefik routing for it; boring gets the probe surface for free.

## Decision

### 1. Failure classification, harness-agnostic

A turn/run is `failed` if **any** of:

- non-zero exit; **or**
- a terminal stream `result` carrying an error; **or**
- **zero `ai_text` AND zero `tool_call` events** across the turn — the `agent_no_output` class.

The third is boring's adoption of `sandboxes`' hard-won rule. Classification lives in the `ParseStream` / Envelope layer ([ARD-0037](ard-0037-agent-harness-provider-contract.md)'s contract), so it applies to **every** harness, not just claude — which is the point, since [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)'s OpenCode is the prone one.

### 2. A verdict on the envelope + distinct exit codes

`turn_complete` gains `verdict: ok | agent_no_output | agent_error | nonzero_exit`. `boring run` maps non-`ok` verdicts to **distinct** non-zero exit codes — [ARD-0013](ard-0013-headless-boring-run.md) §2 already promises "the failure category … emitted as a diagnostic line to stderr"; this gives the categories names. A CI job can now tell "agent refused / produced nothing" from "container build failed."

### 3. Post-turn health probe — web-app loop only

After a turn that touched the dev surface, probe the **active preview origin** (the [ARD-0035](ard-0035-preview-tabs-and-editable-address-bar.md) per-tab dedicated-origin proxy): (a) the dev server responds; (b) the entry document is `200` and non-empty; (c) referenced entry assets resolve. On "dev server up but entry blank," emit a `preview_error` envelope event → rendered as a card in boring-ui and logged as an audit event ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)). This is `sandboxes`' `health_check`, reusing boring's existing proxy (`tools/boring-ui-backend/preview.go`) instead of new routing.

### 4. Scope discipline

The health probe is for the **interactive / `dev:` web loop only**. `boring run` (headless/CI, [ARD-0013](ard-0013-headless-boring-run.md)) and warehouse/batch shapes ([ARD-0034](ard-0034-external-api-and-warehouse-readiness-gaps.md), no localhost UI) get classification (§1/§2) but **not** the preview probe — there is nothing to preview, and probing there would manufacture false failures on jobs where "no web entry" is correct.

## Consequences

### Positive

- **`boring run` stops reporting success on empty agent output** — the failure mode [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)'s chosen harness is specifically prone to. Closes a real correctness gap **before** OpenCode lands, not after the first silent-success incident.
- **Distinct verdicts / exit codes** let both CI and the marketer chat say *why* a turn failed.
- **The preview probe catches "clean build, blank page"** — the class build checks miss — and costs little because the dedicated-origin proxy already exists ([ARD-0035](ard-0035-preview-tabs-and-editable-address-bar.md)).
- **All three signals are audit events** ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)), so failures are greppable history, not just transient UI.

### Negative

- **`agent_no_output` is a heuristic** — a legitimately empty turn ("nothing to change") would classify as failure. Mitigation: a turn that emits `ai_text` saying so is **not** empty (it has `ai_text`); true zero-output turns are vanishingly rare and worth flagging.
- **The probe adds a post-turn round-trip** on the dev loop. Mitigation: a single `GET` against an already-running proxy, gated to `dev:`/boring-ui turns only.

### Neutral

- **Classification lives in the [ARD-0037](ard-0037-agent-harness-provider-contract.md) contract layer.** If ARD-0037 is not adopted, §1 still drops into the existing `parseClaudeStream` as a local helper — the two ARDs compose but don't hard-depend.

## Alternatives Considered (rejected)

- **Keep exit-code-only** ([ARD-0013](ard-0013-headless-boring-run.md) status quo). Rejected: the audited tool demonstrates exit code is a **false signal** for these CLIs, and [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) walks boring straight into it.
- **Probe via a headless browser (real render check).** Rejected for v1: heavyweight; a `200` + non-empty entry + asset-resolve check catches the dominant blank-page case without a browser engine. Revisit if "renders but JS-errors to blank" becomes common.
- **Apply the preview probe everywhere** (including `boring run`/warehouse). Rejected: batch/warehouse ([ARD-0034](ard-0034-external-api-and-warehouse-readiness-gaps.md)) has no web entry; probing there manufactures false failures. Gate to the web loop.

## Implementation Order

1. **Classification helper** in the stream layer — counts `ai_text`/`tool_call`, watches the terminal `result`; unit-test against `claude_test.go` fixtures including a new empty-output capture.
2. **`verdict` on `turn_complete`** (`events.go`) + distinct `boring run` exit codes (`cmd_run`, [ARD-0013](ard-0013-headless-boring-run.md)); stderr diagnostic names the verdict.
3. **Audit events** — `agent.turn_failed{verdict, agent}` via the FIFO ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)/[ARD-0027](ard-0027-opencode-audit-emit-path.md)).
4. **Preview probe** (boring-ui) — after a dev-surface turn, `GET` the active tab's proxy origin; classify entry `200`+non-empty+assets; emit `preview_error` on blank-despite-up. Reuse `preview.go`.
5. **Frontend** — render `preview_error` as a card (`chat.js`), alongside the existing turn cards.
6. **Smoke** — a prompt that makes claude refuse / emit nothing → `verdict agent_no_output`, non-zero exit, audit event; a build that passes but serves an empty index → `preview_error` card.
