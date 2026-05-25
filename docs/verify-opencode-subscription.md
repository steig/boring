# Verifying OpenCode preserves Claude Max subscription billing

This is the protocol document for `scripts/verify-opencode-subscription.sh`. It explains why the verification matters, how to run it, how to interpret the result, and what to do if it fails.

## Why this verification matters

boring-ui's entire architecture rests on a single load-bearing assumption: that OpenCode's Claude provider shells out to the official `claude` binary (which bills against the user's Claude Max subscription) instead of making direct HTTPS calls to `api.anthropic.com` with an API key (which bills per token).

That assumption is documented as a verification gate in [ARD-0020](ards/ard-0020-opencode-as-boring-ui-agent-harness.md) §3, "Subscription-billing preservation is a verification gate, not a documentation claim." The verbatim framing from the ARD:

> OpenCode's documentation says its Claude provider preserves subscription billing by shelling out to the official `claude` binary. That claim has to be verified end-to-end before v1.x ships boring-ui to real marketers — because the failure mode (silently routing through `api.anthropic.com` with an API key instead of the subscription) is exactly the failure mode that violates the stated constraint, and a marketer using boring-ui would have no way to notice.

If verification fails for Claude, the boring-ui harness decision reopens (ARD-0020 Decision 7). Until verification passes, every downstream amendment (ARD-0009 `allowed_tools:`, ARD-0010 OpenCode emit path, ARD-0017 AGENTS.md codegen, the v1.x preset Dockerfile updates) is blocked.

This is not a one-time check. The protocol must be re-run at every OpenCode version bump that touches provider routing — eventually as a CI-runnable check against a sandboxed test account. For now, it's a hands-on protocol.

## Prerequisites

- **A Claude Max account** (Pro and Free are not in scope — boring-ui's audience is paying for Max already).
- **`claude` installed and logged in.** Install: `npm i -g @anthropic-ai/claude-code`. Auth: `claude login` and choose your Claude Max account.
- **`opencode` installed.** Install: `curl -fsSL https://opencode.ai/install | bash` or check https://opencode.ai for the current method.
- **`tcpdump` available** (preinstalled on macOS; `apt-get install tcpdump` on Linux).
- **`tshark` is optional but recommended** for clean SNI extraction. macOS: `brew install wireshark`. Linux: `apt-get install tshark`. Without it the script falls back to `strings | grep`, which is cruder but works.
- **`sudo` access on the machine** — `tcpdump` requires root to open the BPF / raw socket. The script prompts for sudo upfront.
- **`ANTHROPIC_API_KEY` must be UNSET** in the environment. If it's set, `claude` prefers it over OAuth and bills per-token regardless of the OAuth login state, which defeats the verification entirely. The script aborts if it sees `ANTHROPIC_API_KEY`.
- **Browser access to the Anthropic billing dashboard** at https://console.anthropic.com/settings/billing for the manual half of the verification.

## How to run it

One command from the boring repo root:

```bash
./scripts/verify-opencode-subscription.sh
```

The script will:

1. Check `opencode`, `claude`, `tcpdump`, and (optionally) `tshark` are in PATH.
2. Verify `ANTHROPIC_API_KEY` is not set.
3. Verify `claude` has OAuth credentials present (macOS Keychain entry or Linux credentials file).
4. **Pause and ask you to note the dashboard state** (see "Manual verification steps" below). Press Enter to continue.
5. Prepare a fixture project in a tmpdir.
6. Start `tcpdump` capturing TCP/443 traffic on all interfaces, into a pcap file.
7. Start a process-tree watcher that snapshots any `claude` processes seen during the session.
8. Run one `opencode run "..."` invocation against the fixture project — a prompt that requires at least one tool call (listing files + reading one).
9. Stop both watchers, parse the pcap (SNI extraction), correlate with the process-tree snapshots.
10. Print a verdict line: `VERIFICATION: PASS` or `VERIFICATION: FAIL`, with evidence summary.
11. Exit 0 on PASS, 1 on FAIL.

Expected wall-clock duration: **~5 minutes for the script itself**, plus your time on the dashboard half (~5 minutes pre, ~5 minutes post). If you need to install `tcpdump`, `opencode`, or `tshark`, add 20-30 minutes for that.

Optional environment knobs:
- `KEEP_EVIDENCE=1` — retain the tmpdir after exit (otherwise it's cleaned). Useful for inspecting the pcap manually.
- `SKIP_MANUAL_PROMPT=1` — skip the "press Enter to continue after noting the dashboard state" prompt. Use this only if you've already noted the dashboard state separately (e.g. on a re-run).

## Manual verification steps (REQUIRED — the script can't do these)

The script can prove the *network path* (which hostnames are contacted by which processes). Only your eyes can prove the *billing dashboard* reflects the subscription path. Both halves must check out to claim "verified."

**Before running the script:**

1. Open https://console.anthropic.com/settings/billing.
2. Confirm the account is on a **Claude Max** plan (not Pro, not Free).
3. Note the current **"Claude Max usage"** percentage (e.g. "47%"). Write it down.
4. Note the current **"API usage"** dollar amount (e.g. "$3.21"). Write it down.

**After the script completes (regardless of PASS/FAIL):**

5. Refresh the dashboard.
6. Confirm **Claude Max usage has incremented** (even a fraction of a percent — the script's session is small). If it's identical to the pre-run number, the session did not bill against the subscription.
7. Confirm **API usage has NOT incremented** (or only by a trivial amount unrelated to the session — there may be other API activity from other tools on the same account). If it incremented by a non-trivial amount during the script window, the session billed against the API key path instead of the subscription.

Both signals must be consistent with what the script reports:

| Script verdict | Max usage incremented? | API usage flat? | Conclusion |
|---|---|---|---|
| PASS | Yes | Yes | **Truly verified — subscription preserved end-to-end.** |
| PASS | No | Yes | Suspect false positive in the script; investigate (cache hit? local session?). |
| PASS | No | No | Session may have errored before reaching Claude; investigate `opencode-session.log`. |
| PASS | Yes | No | Mixed signal — script saw the subscription path but dashboard saw API usage. Probably unrelated API activity, but verify by re-running. |
| FAIL | n/a | n/a | See the FAIL section below. |

## What "PASS" means

In plain language: OpenCode is treating Claude exactly the way boring-ui's architecture assumes — by invoking the user's installed `claude` binary as a subprocess, which carries the user's Claude Max OAuth credentials and bills against the subscription. boring-ui's marketers will inherit that billing path; their organization's Claude Max plan is what gets used, not a separate API-key bill.

If both the script and the dashboard say PASS, ARD-0020 step 1 is satisfied for Claude. Proceed to:

- ARD-0020 step 2 (re-run the same protocol against Codex with ChatGPT Plus and Gemini with Google AI — though per ARD-0020 §6, these are deferred to v1.x+ even if they pass).
- ARD-0020 steps 3-10 (the amendment work for `allowed_tools:`, audit FIFO, AGENTS.md, preset Dockerfiles, doctor checks).

## What "FAIL" means

The script reports FAIL when the evidence shows OpenCode is *not* using the subscription path for Claude. The decision tree from [ARD-0020 §7](ards/ard-0020-opencode-as-boring-ui-agent-harness.md) opens. The four branches, in order:

### Branch 1 — Investigate the gap (always start here)

Before concluding the harness decision is broken, rule out misconfiguration. Read the evidence the script kept (run with `KEEP_EVIDENCE=1` if you haven't already):

- **`opencode-session.log`** — did OpenCode error out before reaching Claude? Did it pick a different provider (e.g. fell through to Ollama, or a configured fallback)?
- **`ps-snapshot.log`** — was a `claude` process ever spawned? If yes but the script still failed, the issue is likely the network half (cache hit, no actual call to Anthropic).
- **`hosts.txt`** / the pcap — which hostnames were contacted? If `api.anthropic.com` is there but no `claude` process, OpenCode is doing direct API calls (this is the canonical FAIL).

Then verify OpenCode's own configuration:

```bash
opencode providers list           # which providers are configured?
cat ~/.config/opencode/opencode.json  # what does the active config say?
```

If OpenCode is configured to use an API key instead of shelling out to `claude`, the fix may be as simple as changing the provider config. OpenCode's documented Claude-via-subscription mode (sometimes called "claude-code" or similar in OpenCode's provider naming) is what we want — if OpenCode is in "anthropic" mode (API-key), switch it.

If the configuration *is* set to shell out to `claude` and the script still fails, the gap is real. Go to Branch 2.

### Branch 2 — If the gap is fixable upstream

Open an issue against [sst/opencode](https://github.com/sst/opencode) with:
- The output of `scripts/verify-opencode-subscription.sh` (the evidence section).
- OpenCode version (`opencode --version`).
- claude version (`claude --version`).
- A reference to ARD-0020 §3 explaining why subscription preservation is load-bearing for boring-ui.

The boring-ui timeline waits for the upstream fix or for a confirmed workaround. The schedule slip is real but bounded; shipping with wrong billing is worse.

### Branch 3 — If the gap is fundamental (OpenCode cannot preserve subscription billing as architected)

The harness decision reopens. Re-run the ARD-0020 §2 comparison (OpenCode vs Goose vs Aider vs OpenHands vs Cline / Continue) with subscription support as the load-bearing axis. Likely candidates as of writing:

- **Switch to a different harness.** Goose, Aider, or a newer entrant may have caught up. Run this same verification protocol against the candidate.
- **Fall back to per-CLI adapters** (ARD-0020 §1's rejected path). Costly but unblocks boring-ui without violating the subscription constraint. Means shipping with a Claude-only adapter at v1.x and Codex/Gemini adapters as v1.x+ work.

### Branch 4 — Pause boring-ui

If no viable harness exists at decision time, the non-engineer browser surface (ARD-0019) waits. v1.0 of boring ships without boring-ui (which is already the plan per ARD-0019 §7), and the thesis-pivot demo from ARD-0008 waits for the non-engineer surface to materialize later.

This is the worst outcome but not the worst possible outcome. Shipping boring-ui with the wrong billing path to marketers' organizations is the actual worst outcome — quiet over-billing on a credit card that boring's audience doesn't have a process for noticing.

## What to do with the results

### If PASS (script + dashboard both green)

1. File a "verification passed" issue / note in the boring repo with:
   - Date.
   - OpenCode version, claude version.
   - The full evidence block from the script.
   - The before/after dashboard percentages and amounts.
2. Unblock ARD-0020 steps 3-10 (the amendment work).
3. Add a calendar reminder to re-verify on the next OpenCode version bump.

### If FAIL

1. **Ping Tom directly** (do not silently treat this as routine). Subscription verification failure is the load-bearing trigger for the harness-decision reopen — Tom needs to see it.
2. Include in the ping:
   - The full script output (`PASS` summary line + the `── Evidence ──` section + the verdict rationale).
   - Which branch of §7's tree you think applies (1, 2, 3, or 4).
   - Whether you've already done the Branch 1 investigation or are waiting on Tom to drive it.
3. Do NOT proceed with ARD-0020 steps 3-10. Those amendments only make sense if Claude verification passes.

## Known limitations of the script

- **Cannot distinguish Claude Max from Claude Pro or Free.** All three use the same OAuth credential shape. The script confirms OAuth credentials exist; only the dashboard confirms the plan tier. This is unavoidable without reading the credential value, which the script deliberately does not do (credential exfiltration is a security smell).
- **Cannot distinguish subscription `api.anthropic.com` traffic from API-key `api.anthropic.com` traffic at the network layer.** Both hit the same hostname; the distinction is in the Authorization header inside TLS. The script uses the *process tree* (was `claude` spawned?) as the load-bearing signal, with hostnames as supporting evidence. This is why the manual dashboard check is not optional.
- **One session is not a representative sample.** OpenCode may shell out to `claude` for some operations and direct-call `api.anthropic.com` for others (e.g. summarization, embeddings, or "small model" sub-tasks). A passing verification on a one-prompt session does not guarantee subscription preservation across every code path. Re-running with different prompt shapes (long context, multi-tool, large file edit) is recommended before declaring fully verified.
- **macOS Keychain access prompts.** If the script triggers a Keychain unlock dialog while checking the `Claude Code-credentials` entry, that's expected — the script uses `security find-generic-password` without `-w` (no value read), but the lookup itself can prompt. Click "Always Allow" or just "Allow" and the script proceeds.
- **Linux credential path is best-guess.** The script checks `~/.claude/.credentials.json`, which is the documented v2.x location at time of writing. If `claude` changes this, the Linux preflight will false-negative; update the script.
- **Windows is not supported.** Per ARD-0019, Windows is out of scope for boring-ui. If Windows support is added later, this script needs a parallel `tcpdump`-or-equivalent path (e.g. `Pktmon`, or running the protocol in WSL).

## References

- [ARD-0019: boring-ui non-engineer browser surface](ards/ard-0019-boring-ui-non-engineer-browser-surface.md) — the umbrella ARD; §3 names OpenCode as the harness.
- [ARD-0020: OpenCode as boring-ui's agent harness](ards/ard-0020-opencode-as-boring-ui-agent-harness.md) — the sub-ARD this protocol implements. §3 is the verification gate spec; §7 is the fallback tree.
- [OpenCode docs](https://opencode.ai) — provider configuration, install instructions.
- [Anthropic billing dashboard](https://console.anthropic.com/settings/billing) — the manual-check surface.
