# ARD-0006: The profile is the trust anchor — in-container agents cannot modify it

- **Status:** Accepted
- **Date:** 2026-05-23
- **Type:** Mini-ARD
- **Related:** [[ard-0005-security-model-inversion]], [[ard-0002-dbx-as-runtime-dependency]]

## Decision

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
