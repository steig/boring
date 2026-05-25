# ARD-0022: boring-ui session and trust model — single-thread-per-project, single-user lock, hidden auto-branching, silent guardrailed execution

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Sub-ARD of:** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §5
- **Amends:** [ARD-0009](ard-0009-guardrails-codegen-architecture.md) — adds `allowed_paths:` and `save:` to the profile schema
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0010-audit-log-and-prompt-tracing-infrastructure]], [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0021-boring-ui-host-proxy-and-project-picker]]

## Context

[ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §5 names the boring-ui session and trust model in summary form. This sub-ARD captures the load-bearing UX and security decisions in detail, the profile-schema additions they require, and the concrete shape of the chat UI from session-start to save-and-share.

The decisions in this sub-ARD survived a thirteen-question `/grill-me` session and three intermediate clarifications. The decisions are interlocking: the chat-persistence model determines the concurrency model determines the lock UX determines the save flow determines the git-branch shape. Splitting them across multiple sub-ARDs would lose those couplings; keeping them together makes the trade-offs visible.

The thesis underneath all of it is from [ARD-0005](ard-0005-security-model-inversion.md): **guardrails are the trust boundary, not approval clicks.** If the profile says an action is allowed, executing it is correct; if the profile says it's not allowed, blocking it (not prompting for approval) is correct. boring-ui doesn't try to make the marketer responsible for security; it makes the profile responsible. The marketer is responsible for their *intent* (what they ask for); the guardrails are responsible for keeping that intent from becoming damage. This sub-ARD turns that thesis into concrete UX.

## Decision

### 1. Chat persistence: one continuous thread per project, single-user, never reset by save

Each registered project has exactly one chat thread. The thread is the project's ongoing conversation with the AI — every `boring open <project>` session by every marketer for the life of the project appends to the same thread. Saves are punctuation; they do not reset the thread.

The mental model boring-ui sells the marketer is **"Slack DM with the AI about this project."** Persistent, conversational, picks up where it left off. There is no "new session" button; there is no session list; the marketer never sees a UUID. Their experience is "I'm chatting about marketing-site; this is the chat for marketing-site."

Storage: a single JSON Lines file at `/var/lib/boring-ui/threads/<project-slug>.jsonl` inside the container, on a named volume that survives container restart (per `boring open`'s standard volume layout). Each line is one event in the thread — user message, AI response, tool call, tool result, save event, status change. The format mirrors [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)'s envelope (timestamp, type, agent, content, metadata) so the audit pipeline can consume it the same way.

OpenCode's context-window management is responsible for handling long threads — summarization, sliding-window selection, semantic compression. When OpenCode summarizes (drops detail beyond a recent window), the boring-ui chat UI surfaces it cleanly: "Earlier conversation summarized (showing last 50 messages)" with a click-to-expand for the full thread if the marketer wants to scroll back. The summarization is the harness's problem; the UX of explaining it is boring-ui's.

Clearing the thread is an explicit destructive action: `boring close --reset <project>` (a new flag on the existing `boring close` subcommand) wipes the JSONL and removes the thread. The picker offers "Reset chat history" as a destructive action under the project's settings menu, gated by a confirmation. Not in the chat UI's primary navigation — resetting should be rare.

### 2. Concurrency: single-user lock per project with presence + take-over UX

At most one marketer can be active in a given project's chat at any time. If Alice has the lock on `marketing-site` and Bob opens it in his browser, Bob sees a lock screen rather than the chat UI:

```
┌────────────────────────────────────────────────────────────┐
│  marketing-site                                            │
│                                                             │
│  🟢 Alice is currently working in this project.            │
│                                                             │
│  Last activity: 2 minutes ago                              │
│  Currently: "Updating hero text"                            │
│                                                             │
│  [ Ping Alice on Slack ]    [ Wait for the lock to release ]│
│                                                             │
│  ─────────────────────────────────────                     │
│                                                             │
│  No activity from Alice for 25+ minutes?                   │
│                                                             │
│  [ Take over ]                                              │
│    (Alice will see a notification next time she returns;   │
│    her unsaved work stays on her WIP branch — see §3)      │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

The lock is held while a marketer's browser tab is open *and* there has been activity within the configurable idle threshold (default 30 minutes). When Alice closes her tab or hits the threshold, the lock auto-releases; Bob can claim. Bob can also take over immediately at any time (with the warning above) — useful for "Alice went on vacation and forgot to close the tab."

The lock is **at the project level**, not at the file level — because the chat thread is at the project level (§1). Two marketers in the same thread simultaneously would mean two authors writing into the same conversation OpenCode is consuming, which is a different and substantially harder UX (covered in [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)'s rejected alternatives as "concurrent collaborative chat — deferred to v2"). v1.x's single-user lock keeps the model simple.

Lock state is held in the proxy (per sub-ARD-0021), not in the container — that way, the proxy can show presence to other marketers in the picker without spinning up the container just to read its lock state. The proxy queries the container's heartbeat over the Unix socket; if the container is stopped, the lock is implicitly released (a stopped container has no active user).

Presence is shown in the project picker per sub-ARD-0021 §3: green dot + name when a marketer is active; sleeping icon + "Last active 4h ago" when stopped. The presence info comes from the same lock state.

### 3. Git, hidden: per-turn auto-commits to a WIP branch the marketer never sees

Every conversation turn that produces file changes is silently committed to an auto-created WIP branch. The marketer never sees git terminology — no "branches" in the UI, no "commits," no "diffs against HEAD." But under the hood, each turn lands as one git commit with an AI-generated message, on a branch named `boring/wip/<marketer-username>/<thread-resumed-at-timestamp>`.

Branch creation:

- The WIP branch is created lazily — on the first turn that produces file changes after the marketer enters the chat. Talking to the AI without asking for any file changes doesn't create a branch.
- The branch starts from the current `main` (or whatever the profile's `save.target_branch:` is set to per §7) at the moment the first turn fires.
- The branch name uses the marketer's username (read from the proxy's auth state per sub-ARD-0021 §6.2) plus a timestamp marker for the "session" (which here means "this stretch of chat between save events" — see below).

Per-turn commits:

- Each conversation turn that includes tool calls modifying files results in a single commit at the end of the turn. The commit message is AI-summarized from the user prompt + the changes ("Update hero text to highlight summer collection").
- Tool calls that don't modify files (a read, a query against the Postgres sidecar) don't commit.
- Failed tool calls don't commit (the file change didn't land).

This per-turn-commit pattern is what Aider has been doing for years; it's well-trodden territory. The engineer reviewing the resulting PR (per §7) gets a per-turn history they can read top-to-bottom — "Alice asked for X, AI did Y, then asked for X', AI did Y'" — as a built-in audit trail of the design conversation.

Marketer-visible undo (per §4 below) maps to `git revert <commit>` on the WIP branch: the undone change becomes a new commit, the WIP branch advances, the marketer sees the file revert and the preview reload. Per-action undo is per-commit revert. Cumulative state is always the WIP branch's `HEAD`.

After a save (§7), the WIP branch's `HEAD` becomes the basis for the saved PR branch; the WIP branch itself is closed out (or kept around for a grace period — see §7.3). The next file-modifying turn starts a fresh WIP branch.

Cleanup: WIP branches that go N days without activity (default 7) and never produced a save get auto-pruned by `boring sweep` (a new subcommand the proxy invokes on a daily cron). The marketer gets a "you have N old experiments to review" notice in the picker first; sweep only runs if the marketer doesn't intervene. Engineer can configure the threshold per profile (`wip_branch_ttl: 14d`).

### 4. Trust UX during turns: silent execution + inline diff cards + per-action undo; no approval prompts

When the marketer asks for something, OpenCode does it. Every tool call surfaces in the chat thread as a card with type icon, summary, and expandable detail. The preview iframe updates live as files change. The marketer can undo any individual action with one click. There are **no approval prompts** — the guardrails ([ARD-0009](ard-0009-guardrails-codegen-architecture.md), §5 below) decide what's allowed; if a tool call is allowed, it executes; if it's not, it's blocked.

Card types in the chat thread:

| Type | Icon | Example summary | Detail expand shows |
|---|---|---|---|
| Message | 💬 | "Update the hero text to highlight summer collection" | Plain text |
| AI response | 🤖 | "I'll update the hero text. Let me check the current template first." | Plain text |
| File read | 👁 | "Read templates/sections/hero.liquid" | First 100 lines of the file at that moment |
| File edit | ✎ | "Edited templates/sections/hero.liquid — 3 lines changed" | Unified diff (inline, syntax-highlighted) |
| Shell command | $ | "Ran `npm run build`" | Command + stdout/stderr (first 50 lines, expand for full) |
| Network call | ⚡ | "Fetched products from Shopify API" | URL + status + first 500 chars of response |
| DB query | 🗄 | "Queried `select count(*) from products`" | SQL + rowcount/sample row |
| Blocked | 🚫 | "Tried to edit `package.json` — outside allowed paths" | Reason + "Ask an engineer" button (§5.3) |
| Save | 📤 | "Saved as PR #142: 'Update homepage hero'" | PR title, description, link to GitHub |

Every card with a file-change side effect has an **undo button** in its top-right corner. Click → confirm dialog ("Undo: 'Update hero text'? This will revert 3 lines in templates/sections/hero.liquid.") → `git revert` of that commit → preview reloads → a new "↩ Undid: 'Update hero text'" card appears in the thread. Undo is sticky — undone changes are reverted by a new commit, not erased — so engineers reviewing the eventual PR see both the change and the undo, which is the right signal ("the marketer tried this, then changed their mind").

The "stop" button at the top of the chat input cancels the in-flight turn (kills OpenCode's tool loop mid-stream). Partial work landed before the stop stays committed; the next turn picks up from there.

No approval prompts because:

- **They contradict the [ARD-0005](ard-0005-security-model-inversion.md) trust thesis.** If `allowed_tools:` permits the action, prompting the marketer to re-confirm is treating them as the security boundary, which they aren't. The guardrails are. Prompting on top is an admission the guardrails are wrong — and the right fix for wrong guardrails is to fix the guardrails.
- **They train rubber-stamping.** Marketers will hit "approve" on everything within minutes. The prompts become noise that filters bad and good actions equally.
- **They kill the chat flow.** Multi-step work requires multiple tool calls; gating each one on a click means the AI loses its ability to follow up a "read this, then edit, then check" sequence without 15 marketer interactions.
- **They make per-action undo redundant.** Silent + undo is the same trust model (the marketer can always reverse) without the prompt latency.

### 5. File-edit reach: path allowlist enforced at the OpenCode tool-call layer, preset defaults + profile override

OpenCode's file-edit tools are gated by an explicit path allowlist. Each preset ships sensible defaults; profiles can extend (additive) or carve out (subtractive). Out-of-allowlist edit attempts are refused before the tool call executes, with a clear marketer-facing message.

#### 5.1 Profile schema addition

> **Canonical schema definition lives in [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) §3**, which lands these fields in the same guardrails codegen pipeline as `allowed_tools:`. The shape below is reproduced for readability of this sub-ARD; ARD-0026 is the authoritative source for resolution semantics and codegen output.

The profile schema gains `allowed_paths:` and `disallowed_paths:` fields, parallel to the existing `allowed_tools:` shape:

```yaml
# .boring/profile.yaml
allowed_paths:
  - templates/
  - snippets/
  - sections/
  - assets/
  - config/
  - app/copy/                 # additive — extends the preset default

disallowed_paths:
  - .github/                  # subtractive carve-out from preset default
  - alembic/
```

The resolution is: **preset default + `allowed_paths:` − `disallowed_paths:`**, glob-expanded, with the explicit list winning on conflict. The codegen pipeline writes the resolved allowlist into OpenCode's tool-call config at `boring open` time, alongside the existing guardrails artifacts ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)).

#### 5.2 Preset defaults

Each preset's `defaults.yaml` (or equivalent — sibling to the existing per-preset config) carries an `allowed_paths:` list. The v1.0 preset defaults:

| Preset | Default `allowed_paths:` |
|---|---|
| `shopify` | `templates/, snippets/, sections/, assets/, config/, locales/` |
| `django-node` | `templates/, static/, fixtures/, app/copy/, app/content/, frontend/src/, frontend/public/` (migrations explicitly off) |
| `python` | `src/, content/, templates/` |
| `node` | `src/, public/, content/` |
| `node-postgres` | `src/, public/, content/` (migrations explicitly off) |

Defaults are curated for the marketer-as-content-editor case. Engineers authoring custom presets pick their own defaults; engineers authoring profiles can override per project.

#### 5.3 Out-of-allowlist UX

When OpenCode attempts a file edit outside the allowlist, the tool call is refused at the wrapper layer (inserted into OpenCode's tool definition during codegen). The refusal lands in the chat thread as a 🚫 Blocked card:

```
🚫 I can't edit `package.json` — that's outside the
    paths your team has allowed for this project.

    Paths I can edit:
      templates/, snippets/, sections/, assets/, config/, locales/

    [ Ask an engineer to make this change ]
```

The "Ask an engineer" button opens a dialog that drafts a GitHub issue with:

- Title: AI-summarized from the marketer's intent ("Update package.json to add new dependency `foo`");
- Body: the relevant chat-thread excerpt, the specific file path the marketer was trying to reach, the marketer's stated reason, a footer pointing at the boring-ui session;
- Labels: `from-boring-ui`, `marketer-request`;
- Assignees: per profile's `save.reviewers:` config (§7) or repo CODEOWNERS for the requested path.

The marketer reviews the draft, edits if they want, hits "Open issue." The issue gets created; a link card appears in the chat thread. The marketer's request is now an actionable engineer task, not a dropped intent.

### 6. Preview iframe: preset default `preview_url:` + profile override, fallback to diff view

The right pane of the chat UI is the live preview. Each preset declares a sensible default URL; profiles can override or extend.

#### 6.1 Profile schema addition

```yaml
# .boring/profile.yaml
preview_url: http://localhost:8000/
# or for multiple previewable URLs:
preview_urls:
  - name: Frontend
    url: http://localhost:5173/
  - name: Admin
    url: http://localhost:8000/admin/
```

Single `preview_url:` for one-target case; `preview_urls:` (list) for multi-target (rendered as a tab strip at the top of the iframe pane). Missing both → right pane shows a "cumulative diff" view of changes the AI has made in this conversation since the last save.

#### 6.2 Preset defaults

| Preset | Default `preview_url:` |
|---|---|
| `shopify` | `http://localhost:9292/` |
| `django-node` | `http://localhost:5173/` (Vite default) |
| `python` | (no default; cumulative diff fallback) |
| `node` | `http://localhost:3000/` |
| `node-postgres` | `http://localhost:3000/` |

#### 6.3 Iframe loading mechanics

The preview URL is served through the same proxy origin as the chat UI (per sub-ARD-0021 §4): `https://boring.local/<project-slug>/preview/` proxies to the in-container `localhost:<port>/`. Same origin = no CSP fights, no SameSite issues, no mixed-content warnings.

Hot reload is the framework's responsibility: Vite, Webpack, Django's runserver, and Shopify's theme dev server all handle their own websocket-based reload protocols, which work transparently through the proxy. boring-ui doesn't inject anything; it just renders the iframe and trusts the framework to refresh.

When OpenCode makes a file change, the preview reloads on its own (the framework noticed the file change); boring-ui doesn't need to explicitly trigger reload. If the framework doesn't auto-reload (e.g., a profile that's serving static HTML with no dev server), the preview pane has a manual "refresh" button.

### 7. Save mechanics: profile-declared `save:` block, sensible defaults, marketer-friendly dialog

When the marketer hits "Save" in the chat UI, the cumulative diff on the WIP branch (§3) gets promoted to a named branch, pushed to the remote, and opened as a PR per the profile's `save:` configuration.

#### 7.1 Profile schema addition

```yaml
# .boring/profile.yaml
save:
  target_branch: main                    # default: main
  reviewers_from: codeowners             # default: codeowners (alternative: explicit list)
  reviewers: [alice, bob]                # alternative to reviewers_from
  draft_by_default: true                 # default: true
  branch_prefix: "marketer/"             # default: marketer/
  pr_template: ".github/PULL_REQUEST_TEMPLATE/marketer.md"  # default: repo's default PR template
```

All fields optional; missing fields fall back to sensible defaults named above.

#### 7.2 Save dialog

The chat UI's "Save" button opens a dialog:

```
┌────────────────────────────────────────────────────────────┐
│  Save your work                                            │
│                                                             │
│  Title                                                      │
│  [ Update homepage hero text to highlight summer collection ]│
│                                                             │
│  Description                                                │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ Changes the hero section on the homepage to highlight │ │
│  │ the new summer collection launch. Updated copy in:    │ │
│  │   - templates/sections/hero.liquid                    │ │
│  │   - locales/en.default.json                           │ │
│  │                                                        │ │
│  │ Generated from boring-ui chat thread (37 turns).      │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  Branch name                                                │
│  [ marketer/homepage-hero-2026-05-24-3a7f                  ]│
│                                                             │
│  Reviewers                                                  │
│  [✓ Alice  ✓ Bob  + Add reviewer                          ]│
│                                                             │
│  ○ Draft   ● Ready for review                              │
│                                                             │
│  [ Cancel ]                              [ Save and share ]│
└────────────────────────────────────────────────────────────┘
```

All fields editable. Title is AI-generated from the cumulative diff + chat-thread context. Description is structured: summary paragraph + file list + footer pointing at the boring-ui thread. Branch name follows the `branch_prefix:` convention with an AI-derived slug + date + short SHA suffix. Reviewers pre-filled per profile config; user can add/remove. Draft default per profile config.

Clicking "Save and share":

1. Branch from the WIP branch's `HEAD` to the chosen name;
2. Push to remote (`git push -u origin <branch-name>`);
3. Open a PR via `gh pr create` (or GitHub API directly) with title, body, target branch, reviewers, draft flag, and the configured PR template;
4. Close out the WIP branch (per §7.3);
5. Drop a 📤 Save card into the chat thread with the PR link;
6. Redirect the marketer to the PR URL in a new tab (configurable: stay in chat, go to PR, both).

The chat thread continues — saves are punctuation, not breaks (§1). The next file-modifying turn starts a fresh WIP branch.

#### 7.3 WIP branch lifecycle after save

After a successful save, the WIP branch's `HEAD` has been promoted to the saved branch. The WIP branch itself:

- Stays on disk for 24 hours (configurable: `wip_branch_grace: 48h`) in case the marketer wants to recover something they didn't save;
- After the grace period, gets auto-pruned by the `boring sweep` cron;
- Available in the chat UI under "Recent saves" → "View WIP branch" for engineers debugging "what did Alice's session actually look like before the save"; not surfaced to marketers.

#### 7.4 Save failure handling

If the save fails (GitHub auth expired, network down, target-branch conflict, push rejected), the WIP branch is untouched and the chat UI shows a clear, actionable error:

```
⚠ Save failed: GitHub authentication expired.

   Your work is safe on its WIP branch and will be there when you retry.

   Retry options:
     [ Re-authenticate with GitHub ]
     [ Try again ]
     [ Save as a local patch file ]   (downloads <branch-name>.patch)
```

Recovery beats "your work is gone." The local-patch-file option exists for the edge case where GitHub is unreachable for an extended period; the marketer can hand the patch to an engineer to push manually.

### 8. Profile schema additions (combined)

This sub-ARD adds three top-level fields to `.boring/profile.yaml`, all optional with sensible defaults:

```yaml
# .boring/profile.yaml
profile_version: "1"
name: marketing-site
preset: shopify

# Existing fields (allowed_tools, services, env, setup, etc.) unchanged.

# NEW (sub-ARD-0022):

allowed_paths:                           # extends preset default
  - app/copy/
disallowed_paths:                        # carves out from preset default
  - .github/

preview_url: http://localhost:9292/      # overrides preset default

save:                                    # all fields optional
  target_branch: main
  reviewers_from: codeowners
  draft_by_default: true
  branch_prefix: "marketer/"
  pr_template: ".github/PULL_REQUEST_TEMPLATE/marketer.md"
```

Plus a per-profile optional `wip_branch_ttl: 7d` and `wip_branch_grace: 24h` for §3 and §7.3 timeouts.

Schema validation lives in `lib/profile.sh` (existing module). Codegen ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)) writes the resolved values into OpenCode's tool-call config and into a sidecar `boring-ui.json` consumed by the in-container boring-ui backend at session-start.

### 9. Container-side data layout

The container layout for boring-ui state:

```
/var/lib/boring-ui/
├── threads/
│   └── <project-slug>.jsonl     # the single chat thread per §1
├── wip/                          # git worktrees for active WIP branches (optional optimization)
└── boring-ui.json                # codegen output: resolved allowlist, save config, preview URL
```

All under one named volume (`boring-ui-state`) mounted at `/var/lib/boring-ui/`. The volume survives container restart; deleted only on `boring close --reset` or explicit volume deletion.

The boring-ui backend (an in-container Node or Go process; specifics in sub-ARD-0022's implementation step) is started lazily on first browser visit per project, exits when no browser has been connected for the idle timeout.

### 10. Audit emission

Every chat-thread event, every tool call, and every save lands in the audit FIFO per [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) — boring-ui doesn't get its own audit pipeline. The events carry the `agent: opencode` field per sub-ARD-0020 §5.2 so downstream audit consumers can filter by surface.

The marketer-visible chat thread (§1) and the audit log are two views of the same underlying events; the chat thread is the marketer-friendly rendering, the audit log is the engineer-debuggable JSON Lines stream. Engineers who want to see "what's happening in Alice's marketing-site session right now" tail `~/.local/share/boring/audit.log` and filter on `agent: opencode session: <slug>`.

## Consequences

### Positive

- **Marketer mental model is one continuous chat per project.** No session management UI, no UUIDs, no "where was I." Matches the Slack DM model marketers already use.
- **Per-turn git commits give engineers a free audit trail of every PR.** Reviewing the marketer's PR is reading their chat with the AI top-to-bottom, in code form. This is dramatically better than the typical PR ("here's the final diff; figure out why") for AI-assisted work.
- **Silent + diffs + undo is the right trust UX for the [ARD-0005](ard-0005-security-model-inversion.md) thesis.** Guardrails enforce; marketer sees what happened; per-action undo means recovery is one click; no decision fatigue from approval prompts.
- **Path allowlist contains the AI's reach without surprising the marketer.** When something's blocked, the UX surfaces it as "outside what your team allowed" with a one-click path to creating an engineer issue — the marketer's intent isn't lost, it's escalated.
- **Save mechanics piggyback on existing GitHub conventions.** Target branches, CODEOWNERS, PR templates, draft vs. ready — all already part of how teams work. The `save:` block surfaces what teams already have rather than inventing new ceremony.
- **WIP branch lifecycle has built-in recovery.** Failed saves don't lose work; grace period after save lets the marketer recover "wait, I didn't save that thing"; auto-prune means the branch list doesn't grow forever.
- **Single-user lock is simple and the lock UX makes it humane.** Take-over exists for the vacation case; presence indicators tell the team who's where; the lock prevents the hardest concurrency cases without trying to solve them.
- **Audit emission is unified.** Same FIFO, same schema, same collector — engineers debugging or reviewing audit get one source of truth across both surfaces (engineer's `claude` + marketer's OpenCode).

### Negative

- **Single chat per project will pressure OpenCode's context-window management hard.** Months of accumulated chat will hit summarization frequently; if OpenCode's summarization quality is poor, the AI will "forget" things in ways that frustrate marketers. Mitigation: surface "context summarized" cleanly in the UI so the marketer isn't surprised; if quality is genuinely bad in practice, work upstream on OpenCode's summarization or fall back to per-session threads (the rejected Q11B alternative).
- **Single-user lock will frustrate teams that want concurrent collaboration.** "Bob has to wait for Alice" is going to feel old-fashioned for the first month it ships. Mitigation: lock UX is humane; take-over exists; if real demand emerges, v2 reopens the concurrency model.
- **Per-turn git commits clutter the WIP branch history.** A 30-turn session = 30 commits. Mitigation: the saved PR squashes-by-default (configurable via the standard GitHub merge UI); engineers reviewing pre-squash get the play-by-play, which is the right level of detail for AI-assisted work.
- **Path allowlist will block legitimate edits sometimes.** Marketers will hit "I can't edit X" walls that require engineer intervention. Mitigation: the "Ask an engineer" auto-issue flow makes the friction productive (turns the blocked intent into a task) rather than just a wall.
- **The save dialog has a lot of fields.** Title, description, branch name, reviewers, draft toggle — five things to look at. Mitigation: all pre-filled with sensible defaults; marketer in a hurry hits "save" and the defaults work.
- **WIP branches accumulate disk space.** Each session's WIP branch is per-marketer per-resumed-timestamp; over time, a heavily-used project has many. Mitigation: `boring sweep` prunes unsaved branches after the TTL; sweep is daily.
- **Recovery after a long offline period is awkward.** If the marketer's laptop is offline for two weeks, when they come back the WIP branch may have been swept; their session may have summarized aggressively; the project may have moved on. Mitigation: surface "last activity 14 days ago — your previous WIP was pruned" clearly in the chat UI; pre-prune warning in picker so they have a chance to recover before sweep fires.

### Neutral

- **The `save:` block is the new piece of profile authoring engineers learn.** Most teams will set `target_branch:` and `reviewers_from:` and be done. Power users add `pr_template:` and `branch_prefix:`.
- **Per-action undo is one git revert.** Marketers don't see git; engineers reviewing the PR see both the change and the undo as separate commits. Both views are correct.
- **The "Ask an engineer" auto-issue flow uses existing GitHub APIs.** No new infrastructure; just `gh issue create` (or equivalent) wrapped in a marketer-friendly UI.
- **The diff view fallback (when there's no `preview_url:`) is useful in its own right.** Engineers who want "what has the AI done this session" can see it; it's not just a degraded preview.
- **The chat thread storage format is JSON Lines per [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md).** Engineers comfortable with the audit pipeline are immediately comfortable with the chat thread; same envelope, same tools.

## Alternatives Considered (rejected)

- **Ephemeral chat (each tab open is fresh).** Rejected: terrible marketer UX — context gets rebuilt every session, work doesn't survive lunch breaks. Per Q11 grill.
- **Per-session chat threads with explicit lifecycle (session list, archive on save).** Rejected (the Claude facilitator initially recommended this; user chose otherwise): adds session-management UI the marketer doesn't want. "One chat per project" is the simpler mental model. Per Q11 grill.
- **Concurrent collaborative chat (Slack-channel model).** Rejected per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)'s alternatives list: months of engineering for thin marketer demand. Per Q12 grill.
- **Per-marketer thread within a project (each marketer has their own ongoing chat).** Rejected: contradicts Q11C ("one chat per project"); reopens the question the previous decision already settled.
- **Approval-per-action trust UX (every tool call surfaces approve/deny prompts).** Rejected per §4: trains rubber-stamping; contradicts [ARD-0005](ard-0005-security-model-inversion.md); kills chat flow; makes per-action undo redundant. Per Q8 grill.
- **Tiered approval (file edits silent; commands prompt; novel actions prompt).** Rejected: maintaining "known-safe" lists per preset is real work; "novel" is hard to define algorithmically; the first run of anything is novel by definition, so marketers hit prompts often anyway.
- **Working tree only, no auto-commits during chat.** Rejected: tab close = lost work; per-action undo is awkward without per-action commits; engineers reviewing the PR lose the per-turn audit trail. Per Q6 grill.
- **Working tree + periodic auto-snapshot for recovery (every N min).** Rejected: most complex of the three Q6 options; snapshot cadence is a tuning knob; doesn't give engineers the per-turn commit trail. Per Q6 grill.
- **First-port-in-`forward_ports:` as preview URL convention.** Rejected: "first port" is wrong half the time (Django profile has `[8000, 5173]` and the marketer probably wants 5173, not 8000); ordering is a fragile contract. Per Q7 grill.
- **No iframe; preview in a separate browser tab.** Rejected: defeats the side-by-side chat-and-preview UX; marketer has to alt-tab; "see what changed" loses the live feedback loop. Per Q7 grill.
- **Path denylist instead of allowlist.** Rejected per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)'s alternatives list: denylists allow unknown unknowns by default; allowlists fail-closed for the safety case. Same reasoning as [ARD-0009](ard-0009-guardrails-codegen-architecture.md)'s tool allowlist. Per Q13 grill.
- **Always PR to `main`, no per-profile save config.** Rejected: assumes `main` is the right target for every team, assumes CODEOWNERS is universal, assumes PR is the right artifact. Per Q10 grill.
- **Pluggable `on_save:` workflow (arbitrary script triggered by save).** Rejected for v1.x: scope creep; defining the plugin interface is a separate design problem; most teams just want a PR. Per Q10 grill — may be a v2 consideration.
- **Per-file lock instead of per-project.** Rejected: chat is per-project (§1); file-level lock with project-level chat is incoherent.
- **No lock; allow stale state on concurrent access.** Rejected: two browsers both writing to the same chat thread is a recipe for tail-corruption; OpenCode receiving multi-author input is undefined behavior.
- **Squash WIP commits before showing engineers (clean PR).** Rejected as default: the per-turn history is exactly what engineers want for AI PR review. Engineers who prefer squashed history use GitHub's squash-and-merge at merge time; pre-squashing destroys signal unnecessarily.

## Implementation Order

1. **Profile schema additions land in `lib/profile.sh`.** Parse `allowed_paths:`, `disallowed_paths:`, `preview_url:`, `preview_urls:`, `save:` block, `wip_branch_ttl:`, `wip_branch_grace:`. Validate types and shape. Preset-default merging for `allowed_paths:` and `preview_url:`.
2. **Codegen pipeline emits `boring-ui.json` sidecar.** `lib/compose.sh` writes the resolved boring-ui config to `<project>/.devcontainer/boring-ui.json`, bind-mounted RO into the container at `/etc/boring/boring-ui.json`. Read by the in-container boring-ui backend at session-start.
3. **In-container boring-ui backend (server).** A small Go or Node service serving:
   - `/<project>/api/events` — Server-Sent Events or WebSocket stream of OpenCode events;
   - `/<project>/api/messages` — POST endpoint for marketer messages, forwarded to OpenCode;
   - `/<project>/api/save` — POST endpoint that runs the save flow per §7;
   - `/<project>/api/undo` — POST endpoint per §4 undo;
   - `/<project>/api/thread` — GET the full chat thread JSON Lines (paginated);
   - `/<project>/preview/*` — proxy to the configured `preview_url:`;
   - Static assets for the chat UI.
   Started lazily on first proxy hit per project; exits on idle timeout (§9).
4. **Chat UI (client).** Single-page web app in a small frontend framework (React, Svelte, or similar; specifics deferred to implementation time). Renders the chat thread per §4 card types, the preview iframe per §6, the save dialog per §7.2, the lock UX per §2.
5. **WIP branch auto-creation + per-turn commits.** Wrapper around OpenCode tool calls that wraps file-edit tool calls in `git add` + `git commit` per §3. Branch creation on first file-modifying turn; subsequent commits append.
6. **Path allowlist enforcement at OpenCode's tool-call layer.** Per §5.3: tool-call wrapper checks the file path against the resolved allowlist; refuses out-of-allowlist with the blocked card + auto-issue flow.
7. **Single-user lock + presence.** Proxy-side lock state (per sub-ARD-0021); in-container heartbeat to the proxy; lock UX in the chat UI per §2; take-over flow with notification to the displaced user on their next visit.
8. **Save flow.** Save dialog rendering + AI-summarized defaults; `gh pr create` (or equivalent) wrapping; WIP branch lifecycle handling per §7.3; failure-recovery UX per §7.4.
9. **Per-action undo.** Undo button on every file-change card; `git revert` of the corresponding commit; preview reload; new "undid" card in the thread.
10. **Auto-cleanup: `boring sweep` subcommand.** New CLI subcommand for the proxy's daily cron: prune WIP branches past TTL that never got saved; warn marketers in the picker before pruning (24h advance notice).
11. **`boring doctor` integration.** New checks: `allowed_paths:` resolves to non-empty for each preset; `preview_url:` reaches a live server when the container is up; `save.target_branch:` exists on the remote.
12. **Audit emission integration.** Per §10 and sub-ARD-0020 §5.2: chat thread events and tool calls land in the audit FIFO with `agent: opencode` and `session: <project-slug>` fields.
13. **v1.x release.** Lands alongside sub-ARD-0020 (harness) and sub-ARD-0021 (proxy) work — these three sub-ARDs ship together; none is independently user-facing.

Steps 1-2 can begin in parallel with sub-ARD-0020 and sub-ARD-0021 work. Steps 3-12 block on the sub-ARD-0020 harness being available + the sub-ARD-0021 proxy routing being implemented. Step 13 is the joint v1.x release.
