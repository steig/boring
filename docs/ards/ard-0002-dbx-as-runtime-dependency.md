# ARD-0002: dbx is a runtime dependency; boring is a pure secret-resolver, not a store

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0001](ard-0001-v1-architecture.md) — sections "Security — secrets" and "Implementation order"
- **Related:** [[ard-0001-v1-architecture]], [[convention-ards]]

## Context

ARD-0001 proposed (a) extracting dbx's vault module into a shared library (`lib/vault.sh`) that both dbx and boring would source, and (b) giving boring its own secret namespace (`boring/<profile>/<key>`) populated via first-run prompts. Both turned out to be over-engineering:

1. **dbx is already a finished CLI** with stable subcommands (`dbx vault get|set`, `dbx restore`, `dbx config`). Treating it as a *library* consumer couples release cycles, forks a working tool, and creates maintenance overhead for subprocess overhead savings that are not user-perceptible at our call frequency.
2. **boring has no secret of its own to store.** Every value it needs is already someone else's secret: the user's Anthropic key lives in their password manager; dbx host creds live in dbx's vault; the app's Stripe key lives wherever the user keeps their app secrets. Sidecar DB passwords are auto-generated per profile and never persisted. There's nothing left for boring to own.

The correct shape is: boring is a thin **resolver** that maps URIs in the profile to values in whatever store already holds them, and a thin **shell** over dbx for backups.

## Decision

### dbx integration
**boring depends on `dbx` as a runtime CLI dependency, not as a library to fork or extract from.**

- `boring install.sh` checks for `dbx` on PATH. If missing, it offers to run dbx's installer (with explicit `Y/n` consent) or points the user at the dbx install instructions. If present but below the minimum supported version, it offers `dbx update`.
- boring shells out to dbx for **backups**: `dbx restore <uri> --into <container>` (subject to the dbx upgrade — see Open items below).
- boring shells out to dbx for **secrets that live in dbx's vault** via the `dbx-vault:` URI scheme (see resolver below).
- **No shared `lib/vault.sh` in boring. No fork. No coupled releases.**

### Secret resolution — boring owns nothing
**boring does not store any secrets. It does not have a vault namespace. It does not run first-run "save this for you" prompts that take ownership of values.**

The profile declares secret values as URIs into the user's *existing* stores; boring resolves them at container start and injects the raw value into container env. Supported URI schemes:

| Scheme | Resolves to | Backend tool |
|---|---|---|
| `op://vault/item/field` | 1Password item field | `op read` |
| `keychain:service/account` | macOS Keychain / Linux libsecret | `security find-generic-password` / `secret-tool lookup` |
| `dbx-vault:<key>` | dbx vault entry | `dbx vault get <key>` |
| `vault://path/field` | HashiCorp Vault | `vault kv get -field=field path` |
| `aws-sm:<arn>` | AWS Secrets Manager | `aws secretsmanager get-secret-value` |
| `env:VAR_NAME` | Host environment variable | shell |
| `file:/abs/path` | Local file contents | shell |

Profile syntax:

```yaml
env:
  ANTHROPIC_API_KEY: !secret op://Personal/Anthropic/key
  STRIPE_API_KEY:    !secret keychain:com.stripe.test/api-key
  SLACK_TOKEN:       !secret dbx-vault:slack-bot
  DATABASE_URL:      postgres://app@postgres:5432/chat   # not a secret, literal
```

If a URI fails to resolve, boring **fails with a clear, actionable error** naming the URI and the command to populate it manually. For first-time friendliness it may *offer* to walk the user through populating their chosen backend (`Want me to add this to your Keychain now? (Y/n)`) — but the data still lives in *their* store, not in any boring-owned location.

### dbx feature requests (unchanged from ARD-0001)
dbx still needs two upgrades that benefit dbx in its own right and are consumed by boring:

1. `dbx restore --transform=<script>` — streaming sanitization.
2. `dbx restore --into <container-name>` — restore into a named running container, so boring can target a compose sidecar.

Filed as **dbx feature requests** in the dbx repo, not as boring's responsibility.

## Consequences

### Positive
- **No rewrite.** dbx stays a complete, standalone tool. Its tests, its release cadence, its users all stay valid.
- **boring stores nothing.** No vault namespace to manage, migrate, or attack. Zero net-new credential-storage surface area.
- **No new prompts to learn.** Users keep using the secret store they already use. No "where did boring put my Anthropic key" question, because boring didn't put it anywhere.
- **Loose coupling.** boring can ship before the dbx upgrades land; the URI dispatcher can fall back to a clear error ("requires dbx ≥ 0.9.0 for `--into`; run `dbx update`").
- **Independent evolution.** dbx fixes a Postgres regression → all boring users benefit by upgrading dbx, no boring release needed.
- **Smaller surface area for boring.** Fewer modules to author, document, and test.
- **Honors the UNIX-y norm both tools were built in.** Shell scripts composing CLIs > shell scripts sharing libraries.

### Negative
- **Slightly more friction on first run for non-technical users.** "Please add this to your Keychain first" is a real step. Mitigated by the guided-populate flow (boring offers to shell out to `security add-generic-password` / `op item create` for the user) — boring helps populate the user's store without owning it.
- **Subprocess overhead per call.** Negligible — a `boring open` triggers maybe 3–5 dbx/op/etc. invocations total. Each subprocess is <100ms. Not user-perceptible.
- **Version skew.** boring needs to declare a minimum dbx version and check at startup. Mitigation: `boring doctor` validates dbx version; `install.sh` installs/upgrades dbx if too old (with consent).
- **Output parsing.** For values boring reads back from external tools, it depends on their CLI output formats being stable. Mitigated by using each tool's "print bare value to stdout" subcommand (`dbx vault get`, `op read`, `vault kv get -field`) — these are the most stable surfaces.

### Neutral
- **dbx feature requests still required.** ARD-0001's open items #1 and #2 stay — but they're additions to dbx, made via PRs to dbx, not extractions from dbx.

## Alternatives Considered (rejected)

- **Extract `lib/vault.sh` into a shared module** (ARD-0001's original plan). Rejected: over-engineering. Couples two project release cycles. Pulls a working tool apart to enable a not-yet-existing tool. Subprocess overhead is real but trivial compared to the maintenance and coordination cost saved.
- **Vendor dbx into boring.** Rejected: same maintenance cost, plus drift risk. If boring vendors dbx 0.8 and dbx releases 0.9 with a security fix, boring users don't get it until boring re-vendors.
- **Reimplement vault/restore in boring.** Rejected: pointless duplication of working code. dbx is the tool; boring is the launcher.
- **boring owns its own keyring namespace `boring/<profile>/<key>`** (ARD-0001's original secrets plan). Rejected: boring has no secret of its own to store. Every value it consumes already lives in some store the user owns (1Password, Keychain, dbx vault, Vault, AWS SM). Owning a namespace creates a *new* credential-attack surface and a *new* recovery problem ("my Keychain was reset, boring forgot everything") for zero benefit.
- **boring offers to "migrate" values from one backend to another.** Rejected: that's secret-store administration, which is not boring's job. boring resolves; user manages.

## Implementation order (revised — supersedes ARD-0001's Implementation order)

1. **boring CLI skeleton** — entrypoint, `lib/` layout, subcommand dispatcher, `install.sh` outline. No vault extraction; just the shell.
2. **boring's secret-URI resolver** — `keyring:` → shells out to `dbx vault get`. Stubs for `op://`, `vault://`, `aws-sm://`.
3. **Profile schema + parser** — `.boring/profile.yaml` shape, validation, env-var rewrite engine.
4. **Compose generation** — emit `docker-compose.yml` from profile (dev service + declared sidecars).
5. **`boring open`** — wraps clone, profile-read, compose-up, devcontainer-attach.
6. **dbx feature requests** (parallelizable with #3–#5): `--transform` and `--into` upgrades, filed as PRs to dbx.
7. **dbx integration in boring** — `boring open` calls `dbx restore <uri> --into <sidecar>` once both sides are ready.
8. **Egress allowlist mechanism** (iptables-in-container vs. proxy sidecar prototype).
9. **Interactive Claude setup** in `dev` container; per-profile `~/.claude/`.
10. **`boring doctor`**, audit log, metrics hook.
11. **Headless `boring run`** on shared core.
12. **Pluggable vault backends** (`op://`, `vault://`, `aws-sm://`).
13. **`--learn-mode`** for allowlist observation.
14. **`brew` + `winget`** packaging.
