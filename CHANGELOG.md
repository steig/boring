# Changelog

All notable changes to boring are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

VERSION is `0.12.0` — preview iframe on a dedicated origin so Shopify-style root-absolute asset URLs resolve (ARD-0033), plus resizable/collapsible boring-ui panes.

## [0.12.0] — 2026-05-26

### Changed

- **Preview iframe now loads a dedicated-origin reverse proxy, not a same-origin sub-path (ARD-0033, supersedes ARD-0031 §1).** `boring-ui-backend` starts a second HTTP listener on a deterministic per-slug host port (`--preview-port`, range `8700..9199` via `web_ui_preview_port`) that reverse-proxies **at root** to `--preview-url`, stripping `X-Frame-Options` + CSP `frame-ancestors` on every response. The right-pane iframe `src` is now the absolute `http://127.0.0.1:<preview-port>/`.
  - **Why:** end-to-end testing against a real Shopify theme dev server (`shopify theme dev` on `:9292`) showed the storefront references every asset with **root-absolute** URLs (`/cdn/...`, `/checkouts/...`, `/web-pixels@.../`). Under the old `/<slug>/preview/` sub-path those escaped the prefix, hit the host proxy root, and 404'd as `text/plain` with `frame-ancestors 'none'` — producing a wall of MIME ("Refused to apply style/execute script") and framing errors and a blank/broken preview. A `<base href>` can't fix root-absolute URLs; serving the preview at its own origin root makes them resolve back into the proxy. (`:9292` sets `X-Frame-Options: DENY`, so stripping via a proxy is still required — we can't iframe it directly.)
  - The header strip's URL display + open-in-new-tab link continue to show/open the **upstream** URL; only the iframe target moved to the dedicated origin.
  - The backend `/preview/*` sub-path route is removed. WebSocket upgrade + query strings are preserved (HMR / Shopify theme hot-reload keep working). A preview-port bind collision logs a warning and disables the preview without taking down the chat UI.
  - **Known trade-off:** the preview iframe is now cross-origin to the chat UI, so upstream `SameSite=Lax`/`Strict` cookies aren't sent on in-iframe subrequests (cart/session may not persist across navigations). Acceptable for a dev preview; unavoidable given root-absolute upstream URLs. See ARD-0033.

### Added

- **Resizable + collapsible boring-ui panes.** A draggable divider between the left and right panes (pointer-capture so the drag survives crossing the iframes; Arrow-Left/Right nudge when focused), plus header toggles to hide the left pane (`◧`) or the preview (`◨`) — at most one collapsed at a time. Layout (split ratio + which pane is hidden) persists per project in `localStorage`. Works identically whether the left pane is the chat thread or the `--terminal-url` terminal iframe. (`assets/index.html`, `assets/chat.css`, `assets/chat.js`.)
- **Preview address bar tracks in-frame navigation.** As you click around the previewed app, the header URL + open-in-new-tab link update to the current page. Because the preview is now a separate origin (ARD-0033), the chat UI can't read the iframe's location directly, so the preview proxy injects a tiny same-origin script (`/__boring_nav.js`) into proxied HTML that `postMessage`s the current path up to the chat UI, which maps it onto the upstream URL for display. Only the **top** preview frame reports (`window.parent === window.top`), so Shopify's nested web-pixel/analytics sandbox iframes don't pollute the bar. To inject reliably the proxy strips `Accept-Encoding` outbound (Go's transport then transparently decompresses) and, defensively, allows `'self'` in any upstream `script-src`. Catches full page loads + history (`pushState`/`popstate`/`hashchange`) navigations.

## [0.11.0] — 2026-05-26

### Added

- **`boring secret {set|get|rm} <service>/<account>` (ARD-0032).** Provisions a secret into the host OS keyring (macOS Keychain via `security`; Linux libsecret via `secret-tool`) — the same backend the `secret://keychain:` resolver already reads. Lets an engineer/IT drop a credential (e.g. a Shopify Theme Access token) onto a machine once at onboarding; `boring open` then resolves it and injects it via the existing `--remote-env` path with **zero per-use auth**. A non-engineer runs `boring open` (or clicks the project in the boring-ui picker, same `cmd_open`) and the container is pre-authenticated — no OAuth prompt, no vault sign-in, no `.env`. `set` reads the value from **stdin** so it never enters argv or shell history. boring still owns no secret store (ARD-0002 intent preserved): it writes the OS's existing keyring only. `list` is intentionally omitted — enumerating generic-password items is awkward and inconsistent across `security`/`secret-tool`; `get`/`rm` cover the need.

## [0.10.1] — 2026-05-26

### Fixed

- **`chat.js` no longer throws `TypeError: Cannot read properties of null (reading 'addEventListener')` in terminal-pane mode.** When `--terminal-url` is set, `renderIndex` substitutes `{{LEFT_PANE}}` with an iframe only — there's no `#thread`, `#composer`, or `#input` in the DOM. v0.10.0 (and earlier `--terminal-url`-using versions back to v0.8.0) unconditionally called `composer.addEventListener(...)` at script init, throwing immediately and blocking subsequent JS initialization (including the preview-refresh handler attached later in the same file). Fix: detect chat-pane presence once at script init (`hasChatPane`), guard chat-only bindings + render branches, keep SSE attachment + save dialog handlers in BOTH modes so save events still drive toast feedback when the user clicks Save in the terminal-mode UI. Save card rendering (`renderSaveCard`) is gated since it writes to `#thread`; toast still fires for save_succeeded / save_failed.

## [0.10.0] — 2026-05-26

### Added

- **`/preview/*` reverse-proxy route on boring-ui-backend (ARD-0031).** The chat UI's right-pane iframe now loads via `/preview/` on the same origin as the chat page instead of the absolute upstream URL. The backend forwards requests to the configured `--preview-url`, surgically strips iframe-blocking response headers, and preserves WebSocket upgrade so HMR keeps working.
  - `X-Frame-Options` header: deleted entirely on every proxied response.
  - `Content-Security-Policy` header: the `frame-ancestors` directive is scrubbed (case-insensitive, whole-directive-name match) while every other directive (`script-src`, `style-src`, `default-src`, etc.) is preserved. If `frame-ancestors` was the only directive, the whole CSP header is deleted.
  - WebSocket upgrade: passes through `Upgrade: websocket` + `Connection: upgrade` handshake bidirectionally — Vite, Next, Rails (Hotwire), Shopify theme-kit HMR all keep working.
  - Cross-origin headers (`Cross-Origin-Resource-Policy`, `Cross-Origin-Opener-Policy`, `Cross-Origin-Embedder-Policy`) are **NOT** stripped — these govern different cross-origin contexts and don't usually block iframes. Revisit if field evidence shows otherwise.
  - Same-origin iframe additionally dodges `SameSite=Strict` cookie scoping and 2026's credentialed-fetch tightening — chat + preview share one origin, one cookie jar.
- **Closes a v0.9.x ship-blocker:** iframing Shopify (`X-Frame-Options: DENY`) and other production-shaped upstreams was structurally broken — iframe rendered blank regardless of cross-origin / cookie config. Same-origin proxy + header strip makes it work.

### Changed

- **Iframe `src` is now relative `/preview/` instead of the absolute preview URL.** The header strip's URL display and "open in new tab" link still surface the absolute URL so the user knows what's being proxied; only the iframe itself uses the same-origin path.
- **`boring-ui-backend --preview-url` flag doc updated** to note the new `/preview/` reverse-proxy behavior per ARD-0031.

### Files touched

- `tools/boring-ui-backend/preview.go` (new) — `handlePreview` + `stripFrameBlockingHeaders` + `removeFrameAncestorsDirective`. Stdlib-only (`net/http`, `net/http/httputil`, `net/url`, `strings`). Heavily commented with a local-dev-only safety boundary warning at the file top.
- `tools/boring-ui-backend/preview_test.go` (new) — 17 tests across the unit helpers, route registration, end-to-end proxy behavior, path-prefix stripping, host-header rewriting, 404/502 error paths, and stdlib-only WebSocket Upgrade handshake. Uses `net/http/httptest` to mock every upstream — no live Shopify / claude / docker invocation.
- `tools/boring-ui-backend/server.go` — mount `/preview` + `/preview/` routes before the `/` catch-all; iframe `src` in `renderIndex` switched from absolute URL to relative `/preview/`.
- `tools/boring-ui-backend/server_test.go` — `TestIndexPreviewIframeWhenURLSet` updated to assert the new relative-src behavior + guard against the old absolute-src regressing.
- `tools/boring-ui-backend/main.go` — `--preview-url` flag doc updated.
- `boring` — VERSION → 0.10.0.
- `CHANGELOG.md` — this entry.

### Known limitations (transparency)

- **Hardcoded absolute URLs in upstream response bodies aren't rewritten.** If an upstream's HTML/JS/CSS contains absolute `http://127.0.0.1:9292/assets/foo.js` references (rather than relative `/assets/foo.js`), those fetches bypass the proxy. Most modern frameworks emit relative paths, so this affects only a minority of upstreams; documented in ARD-0031 §5. Override `preview_url:` to a path the upstream cooperates with if it bites you.
- **Stripping security headers is contextually safe only because the user is iframing their own local dev server.** Comment at the top of `preview.go` flags this loudly — anyone copying `stripFrameBlockingHeaders` into a general-purpose proxy needs to re-read ARD-0031 §Rationale first.
- **No per-project knob to disable header stripping.** ARD-0031 §Rationale notes "a future config option could let a profile DISABLE header stripping (trust the upstream's framing rules)" — deferred until real demand emerges.
- **Backend uptime is now on the critical path for the preview.** Backend dies → preview dies. Today: backend dies → chat thread also dies, so the marginal cost is small.

## [0.9.1] — 2026-05-26

### Fixed

- **Preset preview-URL defaults switched from `localhost` to `127.0.0.1`** in `web_ui_preset_preview_default` (`lib/web_ui.sh`). Surfaced while testing shop-theme: the v0.8.1 default `http://localhost:9292/` produced a blank iframe even with `pnpm dev` serving correctly inside the container. Root cause is the same IPv6/IPv4 mismatch family as v0.7.x's `IMMICH_HOST` fix — docker-compose port forwards bind IPv4 only by default; macOS resolves `localhost` to `::1` (IPv6) first via getaddrinfo; the iframe request hits IPv6 loopback :9292 (nothing listening), gives up or noticeably delays before retry. Explicit `127.0.0.1` matches what docker-compose actually binds. Updated for all four affected presets: shopify (9292), django-node (5173), node (3000), node-postgres (3000).

  **Profile override unchanged:** if you want `localhost` (e.g. IPv6 testing) or a custom host, `preview_url:` (top-level) or `ui.preview_url:` still wins over the preset default per the ARD-0022 §6 resolution chain — no regression for anyone who's set their own URL.

## [0.9.0] — 2026-05-26

### Added

- **Profile `dev:` block (`lib/profile.sh`).** New optional top-level map; closes the "boring readies the box but no app server, no auth prompt" gap that surfaced when shop-theme was opened in the web UI tonight. Schema:
  - `dev.command` (string OR list-of-strings; required when block present; list entries are joined with spaces — users with quoting nuances should use the string form)
  - `dev.workdir` (container-side absolute path; default `/workspace`)
  - `dev.port` (integer 1..65535; informational only — `forward_ports:` is the real port-forward config)
  Validated + surfaced in the normalized JSON output of `profile_load`.
- **`boring open` foreground dev-command UX (ARD-0030).** After the container is up + setup is complete + (when `--ui`) the boring-ui stack is started, boring runs the profile's `dev.command` in the FOREGROUND via `devcontainer exec ... -- bash -c "cd <dev.workdir> && exec <dev.command>"`. The user's terminal is now the dev server's terminal — they see output, auth prompts, and errors directly.
  - On clean exit (code 0) or Ctrl-C (code 130): teardown via the EXIT trap.
  - On nonzero exit: print an actionable hint (suggests `boring open --no-dev <path>` for in-place debug) then drop into an interactive bash shell so the user can fix the issue without losing the container.
  - When `dev:` is not set or `--no-dev` was passed: drop into the existing interactive bash shell (back-compat with pre-v0.9.0 `boring open`).
- **`--no-dev` flag on `boring open`.** Skip `dev.command` even if the profile sets it; drop into bash shell instead. Documented in `boring help` + the top-of-file usage block. Use when debugging the container or the dev process itself.

### Changed

- **Trap chain hardened (`boring`).** Teardown logic for `cmd_open` (audit collector stop + UI stack stop) is now centralized in a single EXIT trap (`_cmd_open_teardown_all`). INT/TERM traps just `exit 130`; EXIT does the work — `devcontainer exec` frequently eats SIGINT, so the EXIT path is the only reliable safety net. UI teardown is gated on a new `BORING_OPEN_UI_STARTED` flag set by `_cmd_open_maybe_start_ui` on success, so the EXIT trap is a no-op for runs that never enabled `--ui`. Idempotent inner calls mean a redundant INT-then-EXIT cascade is harmless.

### Known limitations (transparency)

- **Foreground design is engineer-in-terminal-shaped.** It does NOT compose with the future ARD-0021 §9 marketer-via-launchd flow (the proxy autostart wants `dev:` running in the background, separately managed) — revisit for v1.x. Marketers should keep using `boring open --ui` for now without `dev:` declared, or wrap the UI launch separately.
- **Single dev command only.** Multi-process projects (concurrent backend + frontend + watcher) should compose them with a wrapper like `concurrently` or `npm-run-all` in the `dev.command` string. A future `dev: { services: [...] }` multi-process shape can come later if users ask.
- **First-run OAuth is still manual copy-paste.** When the dev command needs an OAuth token on first run (Shopify, etc.), the user copies/pastes the URL from the foreground output. Same UX as running the command outside boring.
- **Readiness polling deferred to v0.9.1.** There's no automatic "wait for dev server to bind port X" — the user knows it's up when log lines start flowing. A future minor will add `dev.ready:` (port poll or HTTP probe) so `--ui` can wait before opening the browser.

### Files touched

- `boring` — `--no-dev` parse, new `_cmd_open_teardown_all` + `_cmd_open_maybe_run_dev_or_shell` helpers, trap chain centralization, `BORING_OPEN_UI_STARTED` flag, help/usage updates, VERSION → 0.9.0.
- `lib/profile.sh` — `dev:` schema validation (`dev.command` required + string-or-list shape; `dev.workdir` absolute-path; `dev.port` int range) + normalization (`.dev.command` is always a string downstream; `.dev.workdir` defaults to `/workspace`; `.dev` is null when block absent).
- `tests/fixtures/profile-with-dev-block.yaml` (new) — exercises every field.
- `tests/smoke-dev-foreground.sh` (new) — 27 assertions across 10 test groups: schema (string/list/defaults/all 4 rejection paths/back-compat), `--no-dev` flag surfacing, runner argv via PATH-shimmed `devcontainer` stub, `--no-dev` short-circuit, failure-hint + bash-drop fallback. No live `devcontainer` / `docker` / `claude` invocation.
- `CHANGELOG.md` — this entry.

## [0.8.1] — 2026-05-26

### Fixed

- **In-container `claude` failed to start under `--ui` with `Invalid MCP configuration: mcpServers: Invalid input: expected record, received undefined`.** v0.8.0's `web_ui_ensure_container_claude` wrote `printf "{}" > /etc/boring/empty-mcp.json` — but claude's MCP validator rejects bare `{}` (already verified empirically when boring-ui-backend's `emptyMCPConfigFile()` was written; the only accepted shape is the literal `{"mcpServers":{}}`). Fix: write the exact accepted shape; also remove the `if [ ! -f ]` guard so v0.8.0-installed bad files get corrected on next `--ui` run; also use temp+rename so chmod 0444 from a previous run doesn't block the rewrite (same pattern as v0.7.2 egress fix).

  **Immediate unblock for users on v0.8.0 mid-session:** `docker exec -u root <profile>-dev-1 bash -c 'echo "{\"mcpServers\":{}}" > /etc/boring/empty-mcp.json'` then hit Enter in the ttyd pane to reconnect.

- **Preview iframe showed "No preview configured" for shopify / django-node / node / node-postgres profiles without an explicit `preview_url:`.** v0.8.0's preview-URL resolution stopped at `.ui.preview_url // .preview_url // ""` — never consulted the ARD-0022 §6.2 per-preset defaults table. Fix: new `web_ui_preset_preview_default()` in `lib/web_ui.sh` codifies the table (shopify→`9292`, django-node→`5173`, node→`3000`, node-postgres→`3000`, python→empty); `cmd_open --ui` falls back to it when both profile fields are empty. python preset still requires explicit `preview_url:` since there's no canonical dev-server port.

## [0.8.0] — 2026-05-26

### Added

- **`boring open --ui` + `--no-ui` flags.** Single-command path to bring the dev container up AND wire the boring-ui web stack (singleton host proxy on `:8090`, per-project ttyd serving `docker exec -it <c> claude` with the ARD-0029 guardrail flags, per-project boring-ui-backend on a Unix socket, registry upsert) in one shot. After the container is up + `setup-complete` is marked, boring builds the Go binaries (one-time, ~10s each), spawns the proxy if it's not running, brings up ttyd + backend for the slug, registers the project, prints `[OK] Web UI: http://127.0.0.1:8090/<slug>/`, and opens the browser. Falls through to the existing shell-drop / Ctrl-C-tears-down loop unchanged — engineer gets BOTH the shell AND the browser. `--no-ui` force-disables even if the profile opted in (useful for CI / SSH; SSH sessions also auto-skip the browser open).
- **Profile `ui:` block (`lib/profile.sh`).** New optional top-level map: `ui.enabled` (bool, default false; the opt-in trigger when neither `--ui` nor `--no-ui` is passed) and `ui.preview_url` (string; absolute URL the right-pane iframe loads, wins over the top-level `preview_url` for UI consumers). Validated + surfaced in the normalized JSON output of `profile_load`.
- **`lib/web_ui.sh`** — new module (~390 LOC, bash 3.2-compat). Public functions: `web_ui_required_binaries_present`, `web_ui_build_binaries`, `web_ui_socket_path`, `web_ui_ttyd_port`, `web_ui_proxy_pid_file`, `web_ui_proxy_port`, `web_ui_proxy_running`, `web_ui_proxy_start`, `web_ui_registry_upsert`, `web_ui_registry_remove`, `web_ui_ttyd_start`, `web_ui_backend_start`, `web_ui_stop`, `web_ui_url`, `web_ui_open_browser`, `web_ui_ensure_container_claude`, `web_ui_status`. Deterministic per-slug ttyd port via `printf '%s' "$slug" | cksum` (7681..8679 range; same slug always lands on the same port so reruns reconnect cleanly). Socket path under `$XDG_RUNTIME_DIR/boring/` (Linux) or `$TMPDIR/boring/` (macOS); matches boring-proxy `socketAllowedPrefixes`.
- **`boring ui {status|stop|open} [<slug>]` subcommand.** `status` prints proxy state + per-slug ttyd/backend liveness; `stop <slug>` SIGTERMs the per-project ttyd + backend (proxy stays — other slugs may use it); `open <slug>` (re-)opens the browser to the slug's URL.
- **Auto-build of `tools/boring-{proxy,ui-backend}/`** on first `--ui` use via `make build` in each tool dir. Requires `go` on PATH (with `ttyd`, `docker` — pre-flighted by `web_ui_required_binaries_present` with actionable install hints).
- **`tests/smoke-web-ui.sh`** — 27 assertions across 7 sections: missing-binary detection (PATH=stub trick), socket-path determinism, ttyd-port determinism + range, URL shape, registry upsert preserves other entries + is idempotent + updates fields on re-upsert, registry remove preserves siblings + no-ops on missing slug, `web_ui_ttyd_start` produces the exact ARD-0029 §3 argv (verified via shell-function stub that records argv). No live `claude` / proxy / backend / ttyd spawn — every binary is mocked. Full smoke suite: 8/8 pass (was 7).

### Known limitations (transparency)

- **No automatic cleanup when the container stops.** Stopping the container (Ctrl-C `boring open`) leaves the per-slug ttyd + backend running because they're host-side processes. Use `boring ui stop <slug>` to tear them down explicitly. A future minor will wire this into the existing INT/TERM trap chain.
- **In-container `claude` OAuth is still a one-time manual step.** First time you use `--ui` against a fresh container, you'll need to click through the OAuth flow in the ttyd terminal pane. Subsequent sessions use the cached credential.
- **Proxy runs in `--insecure --no-auth` dev mode.** `boring open --ui` starts the proxy without TLS or token auth so the marketer flow works without the `boring proxy install` ceremony. TLS + per-user token + autostart (ARD-0021 §5-§8) still require `boring proxy install` explicitly; the dev-mode proxy is bound to `127.0.0.1:8090` only, so it's not exposed beyond loopback.
- **Custom Dockerfile presets must install `claude` themselves.** For boring's bundled presets (shopify, django-node, python, node, node-postgres) claude is image-baked. For custom `stack.dockerfile:` profiles (e.g. immich), `web_ui_ensure_container_claude` will fail with an actionable hint: `docker exec -u root <container> npm install -g @anthropic-ai/claude-code`.

## [0.7.4] — 2026-05-26

### Added

- **`boring upgrade` subcommand.** Pulls the latest boring from `origin/main` at the install root (`SCRIPT_DIR` per the existing `readlink -f` resolution). Refuses with a clear error if uncommitted local changes are present (unless `--force`). Supports `--tag <version>` to pin to a specific tag (e.g. `boring upgrade --tag v0.7.3` to roll back). Print before/after VERSION + SHA + links to changelog and releases page.

  Closes the obvious gap that surfaced during v0.7.0–0.7.3's bugfix cascade: the only upgrade path was `cd ~/.local/opt/boring && git pull` or re-running the curl installer.

  Refuses to run if `$SCRIPT_DIR/.git` isn't a directory — i.e. if boring wasn't installed via the curl installer's git-clone path. Prints the install-script command in that case.

## [0.7.3] — 2026-05-26

### Fixed

- **`corepack enable` no longer fails in `postCreateCommand` for `shopify` + `django-node` presets.** Both presets install Node 20 via NodeSource, which does NOT enable corepack by default (unlike the official `node` Docker image). Profiles that included `corepack enable` in `setup:` then hit `EACCES: permission denied, symlink ... -> /usr/bin/pnpm` because the `dev` user can't write to `/usr/bin/`. Fix: add `corepack enable` at image-build time (as root) right after the `npm install -g` line in both Dockerfiles. Profiles can keep `corepack enable` in `setup:` for idempotence or drop it; `pnpm install` works either way. The `python` preset is intentionally unchanged — it ships without runtime npm by design (use `node` / `node-postgres` / `django-node` for Node-needing projects).

  **For users on v0.7.0-0.7.2 with a built shopify/django-node container:** the new Dockerfile only takes effect on container rebuild. Either `docker exec -u root <profile>-dev-1 corepack enable` to patch the running container in place (lasts until next recreate), OR `cd <repo>/.devcontainer && docker compose down && docker image rm <profile>-dev` then `boring open .` to rebuild from the new Dockerfile.

## [0.7.2] — 2026-05-26

### Fixed

- **`egress_write_allowlist_file` re-runs now succeed.** v0.7.1 and earlier wrote `.devcontainer/boring-runtime/egress.allow` then `chmod 0444`'d it (so an in-container agent can't overwrite via the bind mount). Subsequent `boring open` invocations on the same repo failed with `EACCES` at `lib/egress.sh:31` because the redirect `>` couldn't open a 0444 file for writing. Fix: write to `.tmp`, `chmod 0444 .tmp`, then `mv -f` (atomic rename works against the parent dir's perms, bypasses the destination's read-only mode). Matches the `atomicWriteFile` pattern in `tools/boring-proxy/atomic.go`.

  Immediate workaround for users on v0.7.0/v0.7.1: `chmod +w <repo>/.devcontainer/boring-runtime/egress.allow` once; v0.7.2+ doesn't need it.

## [0.7.1] — 2026-05-26

### Fixed

- **`install.sh` no longer collides with `BORING_DATA_DIR`.** The v0.7.0 installer defaulted to cloning into `$HOME/.local/share/boring`, which is also boring's own runtime state directory (`registry.json`, `audit/`, `proxy/`, etc. per ARD-0001). Users who'd ever run `boring proxy install` or seen any boring runtime file got a hard error: `~/.local/share/boring exists but is not a git checkout`. Resolved by moving the default install root to `$HOME/.local/opt/boring`, with explicit back-compat detection for users who already installed at the legacy path before this fix. Resolution order: `$BORING_INSTALL_ROOT` env (always honored) → legacy `~/.local/share/boring/.git` if it's a `steig/boring` checkout → new default `~/.local/opt/boring`.

## [0.7.0] — 2026-05-26

This release bundles all the previously-unreleased work from v0.3 → v0.6 plus the v0.7 slice (harness-agnostic prereqs + save/wip CLI + first major real-stack example).

### Added — v0.7 harness-agnostic prereqs + save/wip CLI + immich example (2026-05-25/26)

- **`boring save <profile|.>`** — promote a WIP branch to a draft PR per the profile's `save:` configuration (ARD-0022 §7). Reads `save.target_branch`, `save.reviewers_from`/`save.reviewers`, `save.draft_by_default`, `save.branch_prefix`, `save.pr_template`. Branches the current WIP head into `<branch_prefix><AI-slug>-<date>-<sha>`, pushes, opens a PR via `gh pr create`. Leaves WIP intact on any failure with an actionable error.
- **`boring wip {start|commit|discard} <profile|.>`** — WIP-branch lifecycle for marketer sessions (ARD-0022 §3). `start` creates `boring/wip/<marketer>/<ts>`; `commit --prompt <text>` stages all + commits with an AI-summarized message via `claude --print`; `discard` deletes (refuses unsaved commits unless `--force`).
- **`lib/saver.sh`** — the underlying module (~330 LOC, bash 3.2-compat). Public functions: `saver_wip_branch_name`, `saver_create_wip_branch`, `saver_commit_turn`, `saver_summarize_turn`, `saver_summarize_pr`, `saver_save`, `saver_discard_wip`.
- **`lib/guardrails.sh`** — new module (~160 LOC) for harness-agnostic codegen per ARD-0026 + ARD-0028. Per-harness translation tables (`_guardrails_claude_tool` / `_guardrails_opencode_tool`) map canonical tool names (`edit`, `run`, `read`, `web_fetch`, `web_search`) to per-harness native names. New codegen artifacts emitted to `.boring/codegen/`: `CLAUDE.md`, `AGENTS.md` (sibling per ARD-0028), `opencode-permissions.json` (per ARD-0026 §4). `guardrails_resolve_paths` computes `(preset default + profile.allowed_paths) − profile.disallowed_paths`. `cmd_open` now calls `guardrails_emit_codegen_dir` after the existing ARD-0009 runtime emit.
- **Profile schema additions (`lib/profile.sh`)** — all optional, sensible defaults:
  - `allowed_paths:` / `disallowed_paths:` — glob lists; resolved at codegen time
  - `save:` block: `target_branch`, `reviewers_from`/`reviewers`, `draft_by_default`, `branch_prefix`, `pr_template`
  - `preview_url:` (string) / `preview_urls:` (list of `{name, url}`)
  - `wip_branch_ttl:` / `wip_branch_grace:` — duration strings (e.g. `7d`, `24h`)
  - **`allowed_claude_tools:` → `allowed_tools:` rename (back-compat alias)** — both keys parse; `allowed_claude_tools:` warns + rewrites to `allowed_tools:` in-memory; hard error if both keys set in the same profile (security-relevant disagreement).
- **`templates/_shared/agent/workflow.md`** — universal CLAUDE.md/AGENTS.md template with substitution tokens (`{{TOOL_EDIT}}`, `{{TOOL_RUN}}`, `{{TOOL_READ}}`, `{{HARNESS_FILENAME}}`, `{{PROFILE_SNIPPET}}`).
- **Per-preset path-allowlist defaults** at `templates/{shopify,django-node,python,node,node-postgres}/allowed-paths.yaml` per ARD-0022 §5.2 verbatim.
- **`examples/immich/`** — first real-world stack example, separate from the curated presets. Custom `stack.dockerfile:` FROM `ghcr.io/immich-app/base-server-dev`; three sidecars (custom postgres with VectorChord+pgvecto.rs, Valkey, immich-machine-learning); forward_ports `[2283, 3000, 9230, 9231]`; ten env vars matching upstream immich's docker/example.env shape. Bring-up confirmed end-to-end through boring: 4 services up, immich API responding on `:2283` (v3.0.0), web frontend on `:3000`.
- **AGENTS.md mount entry in `lib/compose.sh`** — binds `<repo>/.boring/codegen/AGENTS.md` to `/home/dev/.config/opencode/AGENTS.md:ro` per ARD-0028 §3.
- **Test fixtures + smoke tests:**
  - `tests/fixtures/profile-with-boring-ui-fields.yaml` exercises every new field
  - `tests/fixtures/profile-with-deprecated-allowed-claude-tools.yaml` exercises the back-compat path
  - `tests/smoke-boring-ui-schema.sh` — 27-assertion schema smoke
  - `tests/smoke-saver.sh` — 24-assertion save-flow smoke
  - Full suite: 7 smoke tests pass under macOS `/bin/bash 3.2`.

### Added — v0.7 ARDs

- [ARD-0016](docs/ards/ard-0016-repo-side-safety-nets-as-prerequisite.md) — repo-side safety nets (branch protection + per-preset PR templates) as a boring prerequisite; extends ARD-0005 past the container boundary
- [ARD-0017](docs/ards/ard-0017-agent-workflow-rules-derived-from-guardrails.md) — agent workflow rules: preset-baked CLAUDE.md + per-profile snippet derived from `guardrails:` at codegen
- [ARD-0018](docs/ards/ard-0018-vscode-extension-security-and-profile-declaration.md) — VS Code extensions are profile-declared trust-anchor content
- [ARD-0019](docs/ards/ard-0019-boring-ui-non-engineer-browser-surface.md) — boring-ui umbrella (browser surface for non-engineers, post-v1.0)
- [ARD-0020](docs/ards/ard-0020-opencode-as-boring-ui-agent-harness.md) — OpenCode as the agent harness; subscription verification is the precondition gate
- [ARD-0021](docs/ards/ard-0021-boring-ui-host-proxy-and-project-picker.md) — host-side reverse proxy + project picker at `https://boring.local/`
- [ARD-0022](docs/ards/ard-0022-boring-ui-session-and-trust-model.md) — session + trust model (single chat per project, auto-branch, save flow)
- [ARD-0026](docs/ards/ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) — harness-agnostic guardrails + path allowlist (amends ARD-0009)
- [ARD-0027](docs/ards/ard-0027-opencode-audit-emit-path.md) — OpenCode emit path into the same audit FIFO (amends ARD-0010)
- [ARD-0028](docs/ards/ard-0028-agents-md-codegen-sibling-to-claude-md.md) — AGENTS.md codegen alongside CLAUDE.md (amends ARD-0017)
- [ARD-0029](docs/ards/ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) — v0 deviation: `claude --print` shell-out as boring-ui backend because user's opencode lacked configured Claude Code subscription provider; time-bound, swap back to ARD-0020 path when subscription support matures

### Fixed — examples/immich

- **`setup:` mkdir uses portable POSIX for-loop** instead of bash brace expansion (postCreateCommand runs via `/bin/sh`, which created a literal directory named `{encoded-video,thumbs,...}`)
- **`IMMICH_HOST: "0.0.0.0"` env** — without it Node 22+ binds the API only to IPv6 `::1`, and Vite's IPv4-only HTTP proxy gets ECONNREFUSED → web UI shows 502
- **`IMMICH_SERVER_URL: "http://localhost:2283/"` env** — vite.config.ts default proxy target is `http://immich-server:2283/` (a compose service name that exists in upstream's split-container layout but not here)
- **upload subdir markers** (`encoded-video`, `thumbs`, `backups`, `library`, `profile`, `upload`) created with `.immich` files per immich's StorageService system-integrity check

### v1.x preview (not installed by this release)

Substantial boring-ui v0 prototype code lives in `tools/boring-{proxy,ui-backend}/` after this release. **It is not packaged or installed by `install.sh`** and should not be considered part of the supported v0.7 surface. See ARD-0019 for the v1.x plan and ARD-0029 for the v0 deviation that's currently in tree.

- `tools/boring-proxy/` (~2800 LOC Go) — host-side reverse proxy + project picker per ARD-0021
- `tools/boring-ui-backend/` (~3700 LOC Go + HTML/CSS/JS) — in-container chat backend per ARD-0022 with mock + real claude providers, embedded terminal pane (ttyd), path-allowlist enforcement (reactive git revert), per-turn cost tracking
- `scripts/verify-opencode-subscription.sh` + `docs/verify-opencode-subscription.md` — ARD-0020 §3 verification protocol Tom can run when ready

### Added — v0.6 headless `boring run` (2026-05-24, ARD-0013)

- **`boring run "<prompt>" --profile <name>`** — one-shot headless Claude invocation in a profile-scoped sandbox. Fresh container per invocation (compose project name = random suffix, torn down with `docker compose down -v` on exit). Claude prompt is the only input shape — for shell commands use `devcontainer exec` directly. Same secret-resolution code path as `boring open`; CI environment is responsible for non-interactive auth (e.g. `op signin --service-account-token`).
- SIGINT trap catches Ctrl-C mid-run and tears down cleanly (one teardown only — trap resets on first fire).
- `tests/smoke_run.sh` — 18 assertions covering happy path, secret pre-flight failure, SIGINT teardown, `--profile` validation, no-secrets profile, `--help`.

### Added — v0.5 dbx restore integration, boring side (2026-05-24, ARD-0012)

- **`restore:` profile schema** — structured list of `{source, target, transform?, when?}` entries.
  - `target` is cross-referenced against `services:` (fails validation if it names a non-existent sidecar).
  - `transform` is REQUIRED when `data_sensitivity: sanitized` per ARD-0012's safety interlock (the field that's been parsed-but-no-op since v0.2 now becomes load-bearing).
  - `when` is one of `first_up | every_up | manual`; defaults to `first_up`.
  - Profile-level: `restore:` is rejected when `data_sensitivity: internal` (the meaning of "internal" is "no real data ever in this container").
- **`_cmd_open_run_restores`** fires between `devcontainer up` and `setup:` so migrations/seeds run against prod-shaped data, not against an empty schema. Walks the restore list, invokes `dbx restore <source> [--transform=<path>] --into <container>` (container name resolved as `<profile>-<target>-1` via the now-pinned compose project name).
- **`boring restore [<path>] [--refresh]`** subcommand — manual surface over the same pipeline. Idempotent by default (re-runs only entries missing their marker); `--refresh` clears markers and promotes `manual:` entries to `every_up` so they fire on demand.
- **Compose project name pinned to the profile name** (`compose_generate ... --project-name "$name"` in `cmd_open`) so sidecar containers get predictable names rather than the unpredictable `devcontainer-<service>-1` default.
- **`boring doctor` pre-flights `dbx restore --help`** for `--transform` and `--into`; warns explicitly when missing rather than failing mid-`boring open`. Requires dbx ≥ commit `d1f585d` (PR #42 on dbx).
- Marker files at `~/.local/share/boring/restore-state/<profile>/<idx>-<target>.complete`.

### Added — v0.4 egress enforcement + cross-platform `--learn-mode` (2026-05-23/24, ARD-0011 + ARD-0015)

- **iptables-in-container egress enforcement** with `CAP_NET_ADMIN` (not `--privileged`). `install-egress` runs as root at container boot, installs OUTPUT rules from the bind-mounted allowlist file, then drops to the `dev` user via `gosu` before execing user code. `enforce` mode default; `BORING_EGRESS_MODE=learn` swaps `REJECT` for `NFLOG`.
- **`boring open --learn-mode`** records every outbound connection attempt and prints a proposed `egress.allow:` diff on Ctrl-C — the authoring path that makes the allowlist tractable.
- **`ulogd2` sidecar (ARD-0015)** replaces the original dmesg-based learn-mode reader. New `templates/_common/egress-logger/` ships a Debian-slim sidecar with ulogd2 + JSON output plugin; shares the dev container's netns via `network_mode: "service:dev"`; reads NFLOG packets and writes JSON to a host-bind-mounted shared volume that boring's `egress_propose_allowlist_diff` parses. **Works on Mac+Orbstack, which the dmesg path could not** — the dogfood team's daily platform.
- **`lib/egress.sh`** completed (was a stub since v0.1). New host-side functions: `egress_enabled`, `egress_write_allowlist_file`, `egress_propose_allowlist_diff`.
- Egress allowlist file lives at `<repo>/.devcontainer/boring-runtime/egress.allow`; host writes, container reads RO.
- All five presets ship with `iptables`, `iproute2`, `gosu`, `dnsutils` and the `install-egress` entrypoint chain (`tini -- install-egress`).

### Added — v0.3 trust + observability layer (2026-05-23/24, ARD-0009 + ARD-0010)

- **Guardrails codegen (ARD-0009).** Three artifacts generated host-side at `boring open` time and bind-mounted RO into the container at `/workspace/.devcontainer/boring-runtime/`:
  - `pre-push` hook from `guardrails.forbid_branches:` — refuses pushes whose target ref matches a forbidden branch. Repointed `core.hooksPath` from `/etc/boring/git-hooks/` to the bind-mount so the runtime version wins.
  - `bin/<cmd>` wrappers from `guardrails.forbid_commands:` — earlier on PATH than the real binary; prefix-matches argv against the forbidden patterns; passes through to the real binary on no-match.
  - `claude/settings.json` from `guardrails.allowed_claude_tools:` — `jq` deep-merge of the image-baked baseline (ARD-0006 deny rules + ARD-0010 audit hooks) with the per-profile `permissions.allow` list. In-container `~/.claude/settings.json` symlinks to the merged file.
- **Audit log + prompt tracing (ARD-0010).** FIFO + host-side collector for tamper-resistant emit:
  - Per-profile FIFO at `~/.local/share/boring/audit/<profile>/events.fifo`, bind-mounted into the container at `/var/log/boring/events.fifo`.
  - Collector spawned by `cmd_open`; reads events and routes to per-tier JSONL files. Lifecycle traps (INT/TERM/EXIT) ensure no orphaned collectors.
  - **Tiered visibility (ARD-0010 §C22).** Security events (`guardrail_violation`, `egress_block`, `restore`, `command_wrapper_fired`) → `_shared/<profile>/security.jsonl` (profile-wide). Prompt events (`prompt_issued`, `tool_used`, `prompt_completed`) → per-user `<USER>/<profile>/prompts.jsonl` by default; opt-in `audit.prompts: shared` routes to the shared file.
  - **Claude Code native hooks** (`UserPromptSubmit`, `PostToolUse`, `Stop`) wired in the image-baked `settings.json` to invoke `audit-emit-<kind>` shims; the shims write JSON envelopes through the FIFO.
  - **`boring audit security <profile>` / `boring audit prompts <profile>`** subcommands.
  - **Trust-anchor extended** (ARD-0006 + derived requirements): Claude `deny` rules now cover `/workspace/.devcontainer/boring-runtime/**` and `/home/dev/.claude/settings.json` so an in-container agent can't disable its own observability.
- **`audit-emit` shim moved from image-baked → host-emitted RO bind-mount** (fix in `dcce24f`). The original v0.3-dev shipped the script at `/usr/local/boring/bin/audit-emit` in the container's writable layer, where `sudo rm` could disable it. Moved to `/workspace/.devcontainer/boring-runtime/bin/audit-emit{,-<kind>}` so the docker daemon (not file perms) enforces immutability — same trust-anchor pattern as ARD-0006/0009.
- **Five v1.0 presets aligned with full v0.3 wiring** (`f4045a1`): `python`, `node`, `node-postgres` were authored before ARD-0009/0010/0011 and got none of the trust+audit+egress hooks; backported. All five now share the same: iptables/gosu/dnsutils apt installs, `/var/log/boring` FIFO mount target, `core.hooksPath` repoint, PATH prepend for `boring-runtime/bin`, settings.json symlink swap, `install-egress` entrypoint chain, removed `USER dev` (install-egress drops via gosu).

### Added — infrastructure (2026-05-23/24)

- **`scripts/deploy-site.sh`** — push `docs/index.html` to MinIO at `s3.steig.io/public/boring/`. Idempotent; verifies live response after upload.
- **`scripts/test.sh`** — unified smoke test runner. Discovers `smoke*.sh` / `test*.sh` under `scripts/` (excluding non-test scripts like `deploy-site.sh`) and any `*.sh` under `tests/`. Per-test PASS/FAIL/SKIP (exit 77 = skip per autoconf convention). `-v` for inline output; positional arg filters by path substring. 5/5 smoke tests pass locally.
- **`.github/workflows/test.yml`** — CI runs on push + PR to main. `syntax` job runs `bash -n` on every shell file + advisory `shellcheck`. `smoke` job installs `jq` + mikefarah/yq + `@devcontainers/cli`, runs `boring doctor` (warns on missing optional deps like `dbx`), then `scripts/test.sh -v`.

### Added — ARDs landed in this session

- [ARD-0007](docs/ards/ard-0007-django-node-and-multi-service-compose.md) — django-node preset, multi-service compose, schema versioning (covered in v0.2 entry below)
- [ARD-0008](docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) — v0.3→v1.0 release plan + thesis evolution (code as thinking medium for mixed teams)
- [ARD-0009](docs/ards/ard-0009-guardrails-codegen-architecture.md) — guardrails codegen architecture
- [ARD-0010](docs/ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md) — audit log + prompt tracing (FIFO + host collector, Claude native hooks, tiered visibility)
- [ARD-0011](docs/ards/ard-0011-egress-enforcement-via-iptables.md) — iptables egress + `--learn-mode`
- [ARD-0012](docs/ards/ard-0012-dbx-restore-integration.md) — dbx restore via the `restore:` profile field
- [ARD-0013](docs/ards/ard-0013-headless-boring-run.md) — headless `boring run`
- [ARD-0014](docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md) — preset versioning + canonical v1.0 preset list
- [ARD-0015](docs/ards/ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md) — ulogd2 sidecar (amends ARD-0011's dmesg log source)

### Changed

- **Schema versioning + soft deprecations** (ARD-0007 mechanism). `theme:` → `preset:` rename ships as a soft deprecation: both keys parse, `theme:` warns and rewrites in-memory, v2 will hard-remove. Same mechanism handles every future rename.
- **All five presets versioned via build ARGs** (ARD-0014). Profile `preset_version: { python: "3.12", node: "22" }` translates to `--build-arg PYTHON_VERSION=3.12 ...`; defaults baked into each Dockerfile.
- **Compose project name pinned to the profile name** in `cmd_open` (was previously the unpredictable `devcontainer` default from the `.devcontainer/` directory). Sidecar containers now get predictable names like `<profile>-<service>-1`.
- **Marketing site rewritten for the thesis pivot** (`docs/index.html`, commit `8bb7ce7`). Was "AI safely working on prod-shape data"; now "code as a thinking medium for mixed teams (engineers + marketers + managers)." Phased capabilities grid (today / v0.3 / v0.4 / v0.5 / v0.6 / v1.0) replaces the binary today/roadmap split.

### Fixed

- **`audit-emit` script location** (`dcce24f`). Originally shipped in the container's writable layer where `sudo rm` could disable audit; moved to the same host-writes-container-reads-RO bind-mount the rest of the trust anchor uses.
- **bash 3.2 compat in `boring`** (`fb0a2c4` + earlier audit fixes). Removed namerefs (used a documented global instead), used the `${arr[@]+"${arr[@]}"}` empty-array splat idiom, replaced `((c++))` with `c=$((c + 1))` (the `++` form returns nonzero on `c=0` which `set -e` treats as failure).
- **`local bad` shadowing in `_profile_validate_json`** — `bad` was used without `local` before being redeclared later. Fixed.
- **`cd frontend && npm install` in setup chains** — the cwd persisted across the joined shell expression, breaking later commands. Subshelled `(cd frontend && npm install)` in the dogfood profile; documented as a `setup:` ergonomics note.
- **Stale dmesg-based egress smoke** removed (`4f09100`); replaced by `scripts/smoke-ard-0015.sh` exercising the ulogd2 path.

## [0.2.0-dev] — 2026-05-23

### Added (django-node + multi-service compose — 2026-05-23, v0.2 slice)

- **[ARD-0007](docs/ards/ard-0007-django-node-and-multi-service-compose.md)** — `preset: django-node`, multi-service compose, schema versioning, lifecycle hooks, secret resolution at container start. Amends ARD-0004's implementation order step #8.
- **Profile schema versioning.** New top-level `profile_version: "1"` field. Missing → warns; unknown → hard error with upgrade hint. Major-only versioning (no semver). Deprecation table lives in `lib/profile.sh` (`_BORING_PROFILE_DEPRECATIONS_V1`).
- **`theme:` → `preset:` rename (soft deprecation).** `lib/profile.sh` accepts both for v1 schema; warns on `theme:` and rewrites in-memory to `preset:`. v2 will remove `theme:`. shop-theme's existing `theme: shopify` profile continues to work with a warning until migrated.
- **`services:` structured schema.** Sidecars declared as `{name, image, env, volumes, healthcheck, depends_on}` objects. Top-level `volumes:` list for named-volume declarations. `lib/compose.sh` emits multi-service compose with auto-wired `depends_on` on the `dev` service (`condition: service_healthy` when sidecar declares a healthcheck, else `service_started`).
- **`setup:` lifecycle hook.** List of shell commands. `lib/compose.sh` emits them as `postCreateCommand` in `devcontainer.json` (devcontainer-native, fires once on container creation, works with VS Code "Reopen in Container"). `cmd_open` also writes a `/var/lib/boring/setup-complete` marker as the last setup step and re-verifies post-up, re-running setup if the marker is missing (belt-and-suspenders against partial-failure modes like `bootstrap_data` racing Postgres readiness).
- **Secret URI resolution at container start.** `cmd_open` walks normalized env entries, calls `secret_resolve` from `lib/secrets.sh` for each `secret://...` URI, and passes the resolved pairs to `devcontainer up --remote-env KEY=VALUE`. Resolved values never touch disk (not in compose, not in devcontainer.json). Failure to resolve any required secret aborts the open with a clear error naming the URI. Was deferred per ARD-0002's impl order; content-infrastructure forced it (cannot ship `OPENROUTER_API_KEY` as a literal in a checked-in profile).
- **`templates/django-node/`** — `preset: django-node` Dockerfile + supporting files. Base `python:3.14-slim-bookworm`; installs uv (pinned ARG), Node 20 (NodeSource), libpq5, postgresql-client (psql + pg_isready), git, gh, sudo, tini, Claude Code. Non-root `dev` user (uid 1000) with NOPASSWD sudo. `/workspace`, `/home/dev/.config`, `/var/lib/boring` pre-created with `dev:dev` ownership. xdg-open shim verbatim from shopify preset; ARD-0006 trust-anchor enforcement verbatim. Claude defaults via the shared `common` build context (`templates/_common/claude/`).
- **`preset: django-node` defaults seeding.** When a profile declares `preset: django-node` without authoring sidecars/volumes/forward_ports/DATABASE_URL, the normalizer seeds: postgres:17 sidecar (`POSTGRES_DB=content_infra`, `POSTGRES_PASSWORD=postgres`, named volume `postgres-data`, `pg_isready` healthcheck), top-level `volumes: [postgres-data]`, `forward_ports: [8000, 5173]`, `DATABASE_URL` pointing at the sidecar. User-authored values win on conflict (per-key merge for `env`, whole-array replacement for `services`/`volumes`/`forward_ports`).
- **Second dogfood profile: `~/code/work/content-infrastructure/.boring/profile.yaml`.** Django + Django Ninja + React/Vite + Postgres 17. Demonstrates `preset: django-node`, `setup:` hook (uv sync + migrate + npm install + bootstrap_data), `op://` secret URIs for OPENROUTER_API_KEY / WINDMILL_TOKEN / WINDMILL_CALLBACK_API_KEY / DJANGO_SECRET_KEY, and `guardrails.forbid_branches: [main]`.

### Added (Shopify-first v1 slice — 2026-05-23)

- **[ARD-0004](docs/ards/ard-0004-shopify-first-as-dogfood-path.md)** locks Shopify-first as the v1 dogfood path; defers dbx integration + sidecars to v1.x. Adds `mounts:`, `forward_ports:`, `theme:` profile schema fields.
- **[ARD-0005](docs/ards/ard-0005-security-model-inversion.md)** records the security-model inversion (v1 contains the non-engineer + AI from prod systems; egress allowlist deferred to v1.x). Adds `guardrails:` profile schema field.
- **`lib/profile.sh` — full implementation** (replaces the STUB). yq + jq powered. Parses `.boring/profile.yaml`, merges `.boring/profile.overlay.yaml` if present (overlay wins), validates schema (name, theme, stack, services, mounts, forward_ports, env, egress, data_sensitivity, guardrails, claude), and emits a normalized JSON blob downstream modules consume. Tilde-expands `mounts` host paths; classifies env values as `{kind: literal}` vs. `{kind: secret, uri: ...}` (using the `secret://...` convention per the v1 yq-tag pragma).
- **`lib/compose.sh` — full implementation** (replaces the STUB). Emits `.devcontainer/docker-compose.yml` (single `dev` service for the v1 minimal case) and `.devcontainer/devcontainer.json` (dockerComposeFile + service: dev) from the normalized profile JSON. Honors theme presets, source bind-mount, profile mounts, port-forwards, literal env vars. Secret URI resolution deferred to `cmd_open`.
- **`boring open <path>` — functional**. Loads profile, generates `.devcontainer/`, calls `devcontainer up`. URL cloning, secret resolution, egress enforcement, guardrails codegen all deferred.
- **`templates/shopify/`** — `theme: shopify` preset Dockerfile + supporting files. Base `ruby:3.3-slim-bookworm` (matches a typical Shopify theme dev shell — same toolchain `flake.nix`-using projects pin); installs Node 20, Shopify CLI, gh, git, tini, Claude Code. Non-root `dev` user (uid 1000), `/workspace` working dir, port 9292 exposed. Builds in ~34s to 1.45GB.

### Fixed (Shopify-first v1 dogfood smoke test surfaced these)

- **Compose source bind-mount was rooted at `.devcontainer/`, not the repo root.** Generator was emitting `.:/workspace:cached`; relative paths in compose resolve to the compose file's directory, so the container only saw the generated `devcontainer.json` and `docker-compose.yml`. Fixed by emitting `..:/workspace:cached`. (`880c9b8`)
- **`/home/dev/.config` was created as root** when boring's bind-mount for `~/.config/shopify` triggered Docker to materialize the parent. That blocked sibling CLIs like `shopify-cli-kit-nodejs` from writing their own config; `shopify auth login` failed with `EACCES`. Fixed by pre-creating `/home/dev/.config` with `dev:dev` ownership in the Dockerfile. (`7edcdb9`)
- **CLIs that auto-open browsers crashed with `spawn xdg-open ENOENT`** in the headless container, abandoning their polling loops (so even manual browser auth couldn't complete). Fixed by dropping a tiny `xdg-open` shim into `/usr/local/bin` that prints the URL to stderr and exits 0. (`165ccd9`)
- **Profile-side env-var naming collided with project npm scripts.** Set `SHOPIFY_FLAG_STORE` (Shopify CLI's native any-flag env convention), but the project's `npm run dev` script read `$SHOPIFY_STORE` (matching its `.env.example` convention). Fixed in the project profile by setting both names; the lesson — `theme:` presets should set both the CLI-native env var and the project-convention env var documented in the project's `.env.example` — applies broadly.

### Validated end-to-end on macOS against a production Shopify theme

- Container builds in ~34s (1.45GB image), pulls Ruby 3.3.11, Node 20.20.2, Shopify CLI 3.94.3, gh, Claude Code 2.1.150.
- `/workspace` correctly mounts the repo root; git operations inside the container match host state.
- Port 9292 forwards host↔container (`shopify theme dev` hot-reload).
- Shopify auth via device-code flow completes successfully and persists across container rebuilds via the RW bind-mount of `~/.config/shopify/`.
- `npm run dev` serves the dev store with hot-reload visible at `http://localhost:9292`.
- VS Code's Dev Containers extension attaches cleanly to the boring-generated `devcontainer.json`.

### Added (later in the same day — agent guardrails + bundled Claude defaults)

- **[ARD-0006](docs/ards/ard-0006-profile-is-the-trust-anchor.md)** — the profile is the trust anchor. In-container AI agents must NOT modify `.boring/*`. Universal rule, not per-profile opt-in. Enforced by Claude Code permission `deny` + system-wide git `pre-commit` hook installed via `core.hooksPath` in `/etc/boring/git-hooks/` (image-baked, never pollutes the host repo's `.git/hooks/`).
- **Bundled Claude defaults in `templates/shopify/claude/`**, COPYd into `/home/dev/.claude/` at image build:
  - `CLAUDE.md` — Karpathy behavioral guidelines (Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution) + a boring-local footer naming the trust-anchor rule and pointing at any host-repo `CLAUDE.local.md` for project-specific rules.
  - `settings.json` — the trust-anchor `deny` rules (moved out of inline `printf` in the Dockerfile into a real JSON file for readability).
  - `skills/grill-me/SKILL.md` — `/grill-me` available to the user inside the container.

### Added (v0.6 headless `boring run` slice — 2026-05-24)

- **[ARD-0013](docs/ards/ard-0013-headless-boring-run.md)** — headless `boring run` for one-shot Claude invocations in a profile-scoped sandbox. Fresh container per invocation, identical secret code path to `boring open`, same trust-anchor and guardrails posture.
- **`boring run "<prompt>" --profile <name> [--repo <path>]`** — replaces the v0.1 stub. Pre-flights all `secret://` URIs in memory (no disk write) and fails fast on resolution errors before any container starts. Generates a unique compose project name (`boring-run-<profile>-<8-hex-suffix>`) so a one-shot run can't collide with an interactive `boring open` of the same profile. Brings up via `devcontainer up --remove-existing-container` with resolved secrets injected as `--remote-env KEY=VAL` (devcontainer-CLI surface; never written to docker-compose.yml). Invokes `claude -p "<prompt>"` inside the container; streams stdout to the host; exits with Claude's exit code. SIGINT / SIGTERM / normal-exit teardown all converge on `docker compose --project-name … down -v --remove-orphans` (the `-v` removes the run's named volumes, which is the reproducibility property).
- **`lib/compose.sh`** — `compose_generate` now accepts an optional `--project-name <name>` flag that writes a top-level `name:` field into the generated `docker-compose.yml`. Used by `boring run` only; `boring open` continues to omit it.
- **`tests/smoke_run.sh`** — orchestration smoke for `cmd_run`. Uses on-PATH mocks for `op`, `claude`, `devcontainer`, and `docker` (each logs invocation to a JSON-Lines file the assertions check) so the smoke runs without docker / @devcontainers/cli installed and without paying the cost of an actual Claude invocation. Covers: happy path (secret resolution → up → claude exec → teardown), secret pre-flight failure (no container starts), SIGINT mid-run (teardown still fires), `--profile` mismatch rejection, non-slug `--profile` rejection, no-secrets profile (empty `--remote-env` arg list), and `--help`.

### Known UX gaps (filed for next slices)

- `boring open` does not auto-recreate the container when the compose file changes. Workaround: `docker compose --project-name <name> down` before re-running.
- The `theme: shopify` preset's container image is built locally on first run. Publishing to a registry (e.g. `ghcr.io/steig/boring-shopify:v1`) is on the roadmap to cut first-run from ~60s to ~5s.
- `install.sh` is documented as the eventual `curl | bash` install path, but requires the boring repo to go public (or a token-gated install) to work for users beyond the maintainer.


## [0.1.0-dev] - 2026-05-23

Initial scaffold. Design locked, implementation in progress.

### Added

- **Architectural Decision Records** under `docs/ards/`:
  - [ARD-0001](docs/ards/ard-0001-v1-architecture.md) — full v1 architecture (12 design forks resolved via `/grill-me` + DevOps re-evaluation).
  - [ARD-0002](docs/ards/ard-0002-dbx-as-runtime-dependency.md) — amends ARD-0001: `dbx` is a runtime CLI dependency (not a library extraction), and boring owns zero secret storage (pure URI resolver).
  - [ARD-0003](docs/ards/ard-0003-devcontainer-cli-as-runtime-dependency.md) — amends ARD-0001: boring shells out to `@devcontainers/cli` for container lifecycle.
- **`boring` CLI scaffold**: subcommand dispatcher (`open`, `run`, `doctor`, `version`, `help`). `open` and `run` print "not yet implemented" placeholders describing intent.
- **`lib/core.sh`** — paths (`DATA_DIR`, `CONFIG_DIR`, `AUDIT_LOG`, `REGISTRY_FILE`), TTY-aware ANSI colors, logging (`log_info|success|warn|error|step`), `die`, `require_cmd`.
- **`lib/secrets.sh`** — `!secret` URI resolver. Supports `op://`, `keychain:`, `dbx-vault:`, `vault://`, `aws-sm:`, `env:`, `file:`. Fails loudly with install hints when the underlying CLI is missing.
- **`lib/dbx.sh`** — thin wrappers around the `dbx` CLI (`dbx_restore`, `dbx_vault_get`).
- **`lib/devcontainer.sh`** — thin wrappers around `@devcontainers/cli` (`devcontainer_up`, `devcontainer_exec`, `devcontainer_down`).
- **`lib/doctor.sh`** — `boring doctor` environment diagnostics: docker, devcontainer, dbx, optional secret-resolver tools (`op`, `vault`, `aws`, `security`, `secret-tool`).
- **`install.sh`** — checks for required dependencies and prints install hints; downloads boring + lib files to `~/.local/bin/boring` and `~/.local/lib/boring/`. Does **not** auto-install runtimes (ARD-0001 Q9: surprise installers tank trust).
- **`docs/index.html`** — marketing/intro page, also published to `s3.steig.io/public/boring/`.
- **README**, **AGENTS.md**, **LICENSE** (MIT), and this **CHANGELOG**.

### Stubbed (with `TODO(impl, ARD-0002 impl-order #X)` markers)

- `boring open <git-url|.>` — clone, profile-read, compose+devcontainer.json generation, dbx restore, devcontainer up, editor attach.
- `boring run <profile> --task <t>` — headless agent run.
- `lib/profile.sh` — `.boring/profile.yaml` parser, overlay merge, schema validation.
- `lib/compose.sh` — docker-compose.yml + devcontainer.json generation from a parsed profile.
- `lib/egress.sh` — per-profile egress allowlist enforcement (iptables vs. proxy sidecar to be prototyped).

### Verified working on macOS

- `boring help`, `boring version`, unknown-subcommand path
- `boring doctor` correctly reports docker present, dbx present, devcontainer missing
