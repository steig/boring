# ARD-0006: The profile is the trust anchor — in-container agents cannot modify it

- **Status:** Accepted
- **Date:** 2026-05-23
- **Type:** Mini-ARD
- **Extended by:** [ARD-0009](ard-0009-guardrails-codegen-architecture.md) (codegen artifacts join trust-anchor surface), [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) (audit emit path), [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) (CLAUDE.md + workflow snippet), [ARD-0018](ard-0018-vscode-extension-security-and-profile-declaration.md) (extension set + settings), [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) (OpenCode permission config), [ARD-0028](ard-0028-agents-md-codegen-sibling-to-claude-md.md) (AGENTS.md). See "Trust-anchor surface inventory" below for the canonical list.
- **Related:** [[ard-0005-security-model-inversion]], [[ard-0002-dbx-as-runtime-dependency]]

## Decision

> **Scope extended by [ARD-0009](ard-0009-guardrails-codegen-architecture.md) and [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md).** The trust-anchor logic below applies to `.boring/*` (as written). It is also extended to: (a) the **generated guardrails artifacts** (pre-push hook, command wrappers, merged Claude `settings.json`) emitted by ARD-0009 codegen into a host-writes-container-reads-RO bind-mount, and (b) the **audit emit path** (`/usr/local/boring/bin/audit-emit` + the in-container Claude hooks pointing at it) from ARD-0010. Same principle, same enforcement pattern (Claude deny rules + RO bind-mount + system-wide git hook); the protected surface just grows as each codegen feature lands.

`.boring/profile.yaml` (and any sibling file under `.boring/`) is the **trust anchor** for the container that the profile defines. In-container AI agents and processes must not modify it. Enforcement is layered and universal — every boring profile inherits these protections, not by opting in:

1. **Claude permissions `deny`.** Container ships with `/home/dev/.claude/settings.json` containing:
   ```json
   {
     "permissions": {
       "deny": [
         "Edit(/workspace/.boring/**)",
         "Write(/workspace/.boring/**)"
       ]
     }
   }
   ```
   Blocks Claude Code from `Edit`/`Write` on any path under `.boring/`.

2. **System-wide Git pre-commit hook.** Container sets `git config --system core.hooksPath /etc/boring/git-hooks`. The `pre-commit` hook there refuses commits whose staged diff touches `.boring/*`. Catches the "agent ran `vim` via Bash, then committed" path that the Claude-specific deny misses. The hook lives in `/etc/boring/git-hooks/` (image-baked, not in `.git/hooks/`) so the host repo's git state is not polluted.

3. **Documentation.** This ARD + a brief note in `AGENTS.md` documenting the rule, the rationale, and where to legitimately edit a profile (the **host**).

## Rationale

Same principle as Kubernetes RBAC, AWS IAM, or any sound permissions model: the policy that defines what an actor can do must not be modifiable by that actor. The profile defines the container's mounts, ports, egress allowlist (when shipped), allowed Claude tools, branch guardrails, and secret URIs. Letting the in-container agent modify the profile defeats every other guardrail — it's the one rule you can't make optional.

Edits to profiles happen on the **host**, by the human, with intent — reviewable in a PR, traceable in git history. The container reads the profile; the host writes it.

## Consequences

- **Positive.** The trust model holds even when an agent is jailbroken via prompt injection. The agent might be tricked into trying to weaken a guardrail; both the Claude deny and the git hook refuse.
- **Negative.** A human inside the container (via `devcontainer exec ... bash`) trying to edit `.boring/profile.yaml` will be blocked the same way. Acceptable: they exit the container, edit on the host, re-open. That's the right reflex regardless.
- **Neutral.** The Claude deny is a soft layer (Claude Code respects its own permission rules; other AI tools may not). The git hook is the hard backstop. Both are cheap to ship.

## Alternatives Considered (rejected)

- **Make it a per-profile opt-in.** Rejected: there is no legitimate use case for an in-container agent modifying its own sandbox definition. Making it optional invites the "we forgot to enable it" failure mode.
- **Pre-commit hook in `.git/hooks/`.** Rejected: that's host-state inside the bind-mounted repo. Installing the hook from boring would pollute every user's `.git/hooks/`, and host-side git would also enforce the rule (we only want to enforce it from inside the container). System-wide `core.hooksPath` keeps the enforcement scoped to in-container git.
- **Mount `.boring/` read-only.** Rejected: would also block legitimate host edits when the workspace is reopened from inside the container; sudo-as-dev (which our image grants for `apt install` etc.) could `chmod` around the RO flag anyway; doesn't compose well with the bind-mount model.
- **Document the rule only, no enforcement.** Rejected: this is exactly the failure mode any project's `CLAUDE.local.md`-style markdown discipline runs into — an agent under prompt injection won't honor it.

## Trust-anchor surface inventory (canonical)

Each ARD that adds to the trust-anchor surface adds a row here. This is the single canonical list — other ARDs may reference items by name; they should not re-enumerate the list.

| Surface item | Added by | In-container path | Enforcement |
|---|---|---|---|
| `.boring/*` profile + siblings | ARD-0006 (this ARD) | `/workspace/.boring/**` | Claude `deny` + system-wide git pre-commit hook |
| Pre-push git hook | [ARD-0009](ard-0009-guardrails-codegen-architecture.md) | `/etc/boring/git-hooks/pre-push` (RO bind) | RO bind-mount + `core.hooksPath` |
| Command wrappers | [ARD-0009](ard-0009-guardrails-codegen-architecture.md) | `/usr/local/boring/bin/<cmd>` (RO bind) | RO bind-mount + `PATH` precedence |
| Merged Claude `settings.json` | [ARD-0009](ard-0009-guardrails-codegen-architecture.md) | `/home/dev/.claude/settings.json` (RO bind) | RO bind-mount |
| Audit emit binary | [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) | `/usr/local/boring/bin/audit-emit` (RO bind) | RO bind-mount |
| `CLAUDE.md` wiring + workflow snippet | [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) | `/home/dev/.claude/CLAUDE.md`, `/usr/local/boring/agent/workflow.md`, `/workspace/.boring/codegen/workflow-profile.md` | Claude `deny` on `/home/dev/.claude/**` + system-wide git pre-commit hook on `/workspace/.boring/codegen/**` |
| VS Code `extensions:` + `extension_settings:` | [ARD-0018](ard-0018-vscode-extension-security-and-profile-declaration.md) | `.devcontainer/devcontainer.json` (RO bind via ARD-0009) | RO bind-mount; runtime-install lock via [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) egress allowlist (v0.4+) |
| OpenCode permission config | [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) | `/etc/boring/opencode-permissions.json` (RO bind) | RO bind-mount |
| `AGENTS.md` | [ARD-0028](ard-0028-agents-md-codegen-sibling-to-claude-md.md) | `/home/dev/.config/opencode/AGENTS.md` (RO bind) | RO bind-mount |

The enforcement principle is uniform across all rows: the policy that defines what an actor can do must not be modifiable by that actor. Mechanism varies (Claude `deny`, RO bind-mount, git hook) but every row inherits the principle. New ARDs that add to this surface should append a row here, not re-state the principle.
