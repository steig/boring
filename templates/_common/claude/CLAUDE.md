# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## Boring container — local rules

This is a [boring](https://github.com/steig/boring)-managed dev container. Two non-negotiable rules apply on top of the Karpathy guidance above:

1. **Do not modify `.boring/*` files** under any circumstances. The profile at `.boring/profile.yaml` is the trust anchor that defines this container's sandbox — its mounts, ports, secrets, guardrails, allowed tools. Modifying it from inside the container defeats every guardrail at once. The Claude `Edit`/`Write` deny rules + a system-wide git pre-commit hook enforce this; respect them. Profile edits happen **on the host**, by humans, with intent (see [ARD-0006](https://github.com/steig/boring/blob/main/docs/ards/ard-0006-profile-is-the-trust-anchor.md)).

2. **Respect the host repo's existing rules.** The wrapped repo may have its own `CLAUDE.md` / `CLAUDE.local.md` / `AGENTS.md` at the workspace root — especially anything about which branches not to push to, deploy gates, or PR workflows. Follow them. boring's job is to give you a safe sandbox, not to override the project's own conventions.

## Per-profile workflow rules

The rules below are generated from this project's `.boring/profile.yaml` guardrails (forbidden branches, forbidden commands) and mounted read-only by boring (ARD-0017). They are the Claude-side equivalent of the `AGENTS.md` OpenCode reads.

@boring-profile.md
