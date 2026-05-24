# AGENTS.md - boring

A CLI that wraps existing repos in isolated dev containers with realistic DB data and an AI pair preinstalled. Pure Bash. Composes existing tools (`dbx`, `@devcontainers/cli`, `docker compose`) rather than reimplementing them.

**Read first:** [docs/ards/ard-0001-v1-architecture.md](docs/ards/ard-0001-v1-architecture.md), amended by ARD-0002 (dbx integration, no secret storage) and ARD-0003 (devcontainer CLI for lifecycle). The implementation order in ARD-0002 is the canonical roadmap.

## Project Structure

```
boring                  # Main entrypoint, cmd_* dispatchers (open, run, doctor, version, help)
lib/
  core.sh               # Paths, colors, logging, require_cmd, die
  secrets.sh            # !secret URI resolver — op://, keychain:, dbx-vault:, vault://, aws-sm:, env:, file:
  dbx.sh                # Thin wrappers around `dbx` CLI (restore, vault get) — per ARD-0002
  devcontainer.sh       # Thin wrappers around @devcontainers/cli (up, exec, down) — per ARD-0003
  profile.sh            # Parses .boring/profile.yaml, overlay merge, schema validation, normalized JSON.
  compose.sh            # Emits docker-compose.yml + devcontainer.json from a parsed profile.
  egress.sh             # STUB. Per-profile egress allowlist enforcement (deferred to v1.x per ARD-0005).
  doctor.sh             # `boring doctor` diagnostics — docker, devcontainer, dbx, optional URI tools.
install.sh              # Curl installer; checks deps, does NOT auto-install runtimes (ARD-0001 Q9).
templates/
  _common/              # Shared across all theme presets; wired into each preset's
                        # build via compose `additional_contexts: { common: ... }`.
                        # Preset Dockerfiles pull from it with `COPY --from=common`.
    claude/             # Baked into /home/dev/.claude/ in every container:
      CLAUDE.md         # Karpathy behavioral guidelines + boring local rules.
      settings.json     # Claude Code permissions (trust-anchor deny).
      skills/grill-me/  # User-invokable `/grill-me` skill.
  shopify/              # Theme preset (used when profile declares `theme: shopify`).
    Dockerfile          # Toolchain, dev user, trust-anchor enforcement (ARD-0006).
                        # COPY --from=common claude/ /home/dev/.claude/ at the end.
    .dockerignore
    README.md
docs/
  index.html            # Marketing/intro page (also published to MinIO at s3.steig.io/public/boring/).
  ards/                 # Architectural Decision Records. New material decisions go here.
```

Anything not yet implemented is marked `STUB` in the file header and contains a `die "... not yet implemented"` body plus a `TODO(impl, ARD-NNNN impl-order #X)` comment.

## Build / Lint / Test Commands

There is no build step. Pure Bash.

### Linting

```bash
# ShellCheck (mirror dbx's CI: severity=error)
shellcheck boring lib/*.sh install.sh

# Bash syntax check
bash -n boring install.sh && for f in lib/*.sh; do bash -n "$f"; done
```

### Testing

No test suite yet. When tests land, follow dbx's two-tier bats layout: `tests/unit/` (pure functions, no docker, fast) and `tests/integration/` (real docker, runs through `boring open` against a fixture repo). See [dbx's AGENTS.md](https://github.com/steig/dbx/blob/main/AGENTS.md#testing--ci) for the bats helpers pattern.

### Smoke test

```bash
./boring help
./boring version
./boring doctor
```

## Architectural Discipline

This project keeps **ARDs** for every meaningful design choice. Two flavors:

- **Full ARDs** (`docs/ards/ard-NNNN-<slug>.md`) — material decisions with downstream consequences. Sections: Status, Date, Deciders, Context, Decision, Consequences (positive/negative/neutral), Alternatives Considered, Implementation Order. See [ARD-0001](docs/ards/ard-0001-v1-architecture.md) for the template in use.
- **Mini-ARDs** — smaller decisions still worth recording. Sections: Status, Date, Decision (1-3 sentences), Rationale (1-2 sentences). Same file format and numbering. See [ARD-0003](docs/ards/ard-0003-devcontainer-cli-as-runtime-dependency.md).

**When to write one.** Any decision touching the public CLI surface, security model, secret/data flow, runtime choice, or interop with `dbx` or `devcontainer` CLI. Choices between two libraries/patterns where the loser had real merit. Write at the time of the decision, not after.

**Supersession.** A superseded ARD changes its `Status` line to `Superseded by ARD-NNNN` and stays in place. The superseding ARD lists what it supersedes in its header. Never delete.

**Reference ARD numbers in code.** Comments that explain a non-obvious choice should cite the ARD: `# Per ARD-0003, no docker compose up here — devcontainer CLI handles it.`

## Code Style

Mirrors `dbx` exactly. When in doubt, do what `dbx` does — both projects intentionally share conventions so an engineer (or agent) familiar with one feels at home in the other.

### Shell conventions

- **Shebang:** `#!/usr/bin/env bash` on all files
- **Strict mode:** `set -euo pipefail` in the main `boring` script only (not in libs)
- **Quoting:** Always double-quote: `"$var"`, `"$@"`, `"${array[@]}"`
- **Variable declaration:** `local` for all function-scoped variables
- **Command substitution:** `$(cmd)` not backticks
- **Conditionals:** `[[ ]]` not `[ ]`
- **String comparison:** `[[ "$var" == "value" ]]` (double equals)

### Naming

- **Functions:** `snake_case` — e.g., `profile_load`, `secret_resolve`
- **Command functions:** `cmd_<name>` in main `boring` script (e.g., `cmd_open`)
- **Module-prefixed helpers:** `profile_*`, `compose_*`, `secret_*`, `dbx_*`, `devcontainer_*`, `egress_*`, `doctor_*`
- **Global constants:** `UPPER_SNAKE_CASE` — e.g., `DATA_DIR`, `AUDIT_LOG`
- **Local variables:** `lower_snake_case`
- **Environment overrides:** `BORING_` prefix — e.g., `BORING_DATA_DIR`, `BORING_LIB_DIR`

### Error handling

- `die "message"` for fatal errors (logs to stderr, exits 1)
- `log_error` for non-fatal errors
- `log_warn` for warnings
- `require_cmd <name> [<install-hint>]` for required CLI dependencies — fails with the hint if missing
- Check command existence with `command -v cmd &>/dev/null`
- Use `|| true` to prevent `set -e` from exiting on expected failures

### Logging

Use functions from `lib/core.sh`:

```bash
log_info "message"      # Blue [INFO]
log_success "message"   # Green [OK]
log_warn "message"      # Yellow [WARN] (stderr)
log_error "message"     # Red [ERROR] (stderr)
log_step "message"      # Cyan ==> Bold
die "message"           # log_error + exit 1
```

### Lessons from dbx worth carrying over

Lifted from `dbx/AGENTS.md` — the same Bash + Docker landmines apply here:

- **`((var++))` under `set -e`** returns 1 when `var` was 0 → script exits. Use `((var++)) || true`.
- **`cmd1 | cmd2 | head -N` under `set -o pipefail`.** If `cmd1` exits non-zero, the whole pipeline does. Append `|| true` inside `var=$(...)`.
- **Cross-platform `sed`.** GNU vs. BSD differ on `-i`, regex classes. Use POSIX classes (`[[:space:]]`); for `-i`, do a temp-file rewrite instead.
- **Don't install EXIT traps at module load time.** A lib that calls `trap '...' EXIT INT TERM` on source clobbers the caller's trap. Define the function; have the main script invoke it.
- **`local x=$(cmd)` masks return codes (SC2155).** Split `local x; x=$(cmd)` so `set -e` can see failures.

## Adding a new command

1. Add `cmd_<name>()` to `boring`.
2. Add the case to `main()` dispatcher.
3. Add to `cmd_help()` output.
4. Update the usage block at the top of `boring`.
5. If it needs a new module, create `lib/<name>.sh`, source it in `boring` after `core.sh`.

## Adding a new lib module

1. Create `lib/<name>.sh` with `#!/usr/bin/env bash` shebang and a header comment naming the file and its responsibility.
2. Source it in `boring` after its dependencies (`core.sh` first).
3. Prefix public functions with the module name (`<name>_<verb>`).
4. Update `install.sh` to include the file in the download list.
5. Don't fire EXIT traps or other side effects at module load time.
6. Annotate stub functions with `TODO(impl, ARD-NNNN impl-order #X)` so the trail back to the design is one click.

## Architectural invariants (don't violate)

- **boring does not own secret storage** (ARD-0002). New URI schemes go in `lib/secrets.sh` as dispatch cases — never as a new keyring/file/etc. that boring writes to itself.
- **boring does not implement container lifecycle** (ARD-0003). `docker compose up/down` calls go through `lib/devcontainer.sh` wrappers, not scattered through the codebase.
- **boring does not vendor dbx** (ARD-0002). All backup/restore/dbx-vault calls go through `lib/dbx.sh`.
- **Profile is repo state, not user state** (ARD-0001). `.boring/profile.yaml` lives in the wrapped repo; the only user-state file is the registry at `~/.local/share/boring/registry.json`.
- **The profile is the trust anchor** (ARD-0006). In-container agents and processes must NOT modify `.boring/*`. Enforced by container-side Claude permission deny + system-wide git pre-commit hook in `/etc/boring/git-hooks/`. Profiles are edited on the HOST, by humans, with intent. Any new theme preset Dockerfile must include the same enforcement scaffolding — see `templates/shopify/Dockerfile`.
