# ARD-0021: boring-ui host-side reverse proxy + always-running project picker

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Sub-ARD of:** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §4
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]]

## Context

[ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §4 names a host-side reverse proxy as boring-ui's bridge between the browser (on the host) and the chat UI (in the container), with an always-running project picker as the launch surface. This sub-ARD captures the why, the what, and the how-it-works in detail.

The problem the proxy solves has three faces:

**First — the browser-to-container bridge has to handle origin discipline.** The chat UI runs in the container; the live preview iframe (Q7 of the grill, captured in sub-ARD-0022) renders the user's app, which also runs in the container, on a *different port*. Browsers treat different ports as different origins; iframing across them triggers cookie scoping issues, mixed-content warnings, and a forest of CSP / SameSite / CORS misery. The two have to appear on the same origin for the side-by-side chat-and-preview UX to work. A reverse proxy on the host lets boring-ui serve both surfaces under one origin (`boring.local`), routing paths to the right container service internally.

**Second — the marketer cannot type a terminal command to start their work.** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)'s entire point is that the marketer surface doesn't require a terminal. But today's `boring open <repo>` is a terminal command. Something has to launch the container and route the browser to it without the marketer typing anything. The proxy, if it's already running, can be that something — show the marketer a project picker, run `boring open` on their behalf when they click a project, route the browser into the resulting container.

**Third — multi-project workflow is the common case.** A marketer at a real organization works on several projects (the company blog, the marketing site, the help center). Asking them to remember "this project is on port 3737, that one's on 3738" fails immediately. A proxy on a stable domain with path-based routing (`boring.local/blog/`, `boring.local/help-center/`) keeps the URL human-shaped and the project picker the canonical entry point.

The proxy is the only new always-running host-side process boring adds in v1.x. Everything else in boring is invoked on demand. That cost is real and named explicitly in [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)'s Consequences; this sub-ARD locks the mechanics that keep that cost bounded.

## Decision

### 1. boring-ui's browser-to-container path is a host-side reverse proxy

The browser hits a stable host (`https://boring.local/`); the proxy terminates the TLS connection and forwards requests to in-container services over the host-private bridge. The proxy is the single point of entry from the browser for *everything* boring-ui-related — chat UI, websocket / SSE event stream for OpenCode output, the iframe'd live preview, static assets, the project picker landing page.

This replaces the alternatives (forward-port-only, tunneling service) per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §4. The load-bearing reason: iframe-the-preview requires same-origin between the chat UI and the preview. A forward-port approach puts each on its own port (different origin); a tunnel adds latency and external dependency without solving the origin problem. The proxy is the answer that holds the iframe UX together.

### 2. The proxy is always-running, started by `launchd` (macOS) or `systemd --user` (Linux), registered at install time

The marketer opens their bookmark — `https://boring.local/` — and the proxy is already up. They don't run anything; they don't wait; they don't see a loading state.

The proxy starts at user login via:

- **macOS:** a `LaunchAgent` plist at `~/Library/LaunchAgents/io.boring.proxy.plist`, registered when the marketer (or the engineer installing for them) runs `boring proxy install`.
- **Linux:** a user-scoped `systemd` unit at `~/.config/systemd/user/boring-proxy.service`, enabled with `systemctl --user enable boring-proxy`.
- **Windows:** deferred to v1.x+ alongside the rest of Windows support; Windows users on v1.x run the proxy manually via `boring proxy serve` until first-class autostart support lands.

The proxy is **lightweight** — a single Go binary (or small Caddy / Traefik config; see §10's alternatives) on the order of 10-30 MB, idling at single-digit MB of RAM. The always-running cost is real but small; comparable to having a Spotlight indexer or other background utility running.

The proxy is **lifecycle-stateless**: state lives in `~/.local/share/boring/` (the existing registry from [ARD-0001](ard-0001-v1-architecture.md), plus a small proxy-config file and a token directory; see §6). The proxy can be killed and restarted at any time without losing data. This makes upgrades and crashes tolerable — the next launchd/systemd start picks up exactly where it left off.

### 3. The proxy serves a project picker at `https://boring.local/` as the launcher surface

When a marketer hits `https://boring.local/` with no path, they see a project picker:

```
┌────────────────────────────────────────────────────────────┐
│  boring                                  Alice ▾  Settings │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  Your projects                                              │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────┐  │
│  │ 🟢 marketing-   │  │ 💤 help-center   │  │ + Add a    │  │
│  │    site          │  │                  │  │   project  │  │
│  │ Running          │  │ Stopped — 4h ago │  │            │  │
│  │ "Updating hero  │  │ Last save: PR    │  │            │  │
│  │  text" — 2 min  │  │  #142            │  │            │  │
│  │  ago            │  │                  │  │            │  │
│  └─────────────────┘  └─────────────────┘  └────────────┘  │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

The picker reads the existing registry (`~/.local/share/boring/registry.json`, established in [ARD-0001](ard-0001-v1-architecture.md)) and shows one card per registered project. Each card carries:

- **Project name** (from `name:` in `.boring/profile.yaml`, falling back to the directory name);
- **Status** (`🟢 Running`, `🟡 Starting…`, `💤 Stopped`, `🔴 Error`);
- **Current session summary** (one line, AI-generated from the active chat thread per sub-ARD-0022 — "Updating hero text" — or last-save info if the project is stopped);
- **Presence indicator** if another marketer is currently in this project ("Bob is here").

Clicking a card:

- If the container is running → redirect to `https://boring.local/<project-slug>/` (the boring-ui chat surface for that project).
- If the container is stopped → start it via the existing `boring open <project-path>` code path, show a loading state with progress messages ("Building container… Resolving secrets… Starting Postgres sidecar… Running setup…"), redirect when ready.
- If another marketer has the lock → show the lock UX from sub-ARD-0022 §3 ("Bob is here. Wait, take over, or ping him").

The picker uses the same chrome (header, settings menu) as the chat UI for consistency. Settings reachable from here:

- Theme (light/dark/system);
- Proxy status (running, port, TLS cert state);
- Container auto-shutdown timeout (default 2h idle; see §8);
- Sign out (clears the per-user proxy token; next visit requires re-auth);
- About / version.

The "+ Add a project" card opens a flow described in §7.

### 4. Multi-project routing is per-path under one origin

The proxy routes by path prefix:

| URL | Routes to |
|---|---|
| `https://boring.local/` | Project picker (proxy serves directly; no container involvement) |
| `https://boring.local/<project-slug>/` | boring-ui chat UI for `<project-slug>`, in the corresponding container |
| `https://boring.local/<project-slug>/preview/` | Live preview iframe target (the container's app port, proxied) |
| `https://boring.local/<project-slug>/api/` | boring-ui backend API (chat events, save actions, OpenCode event stream) |
| `https://boring.local/<project-slug>/assets/` | Static assets served by the container |

`<project-slug>` is derived from the profile's `name:` field, normalized to lowercase-kebab. Duplicate names across registered projects are disambiguated at registration time (the "Add a project" flow refuses to register a name that collides; offers a suggested suffix).

Each project's container exposes its services on host-private ports (the existing `boring open` behavior); the proxy holds a per-project routing table mapping `<project-slug>` to those ports. The table is rebuilt on each `boring open` / `boring close` event (via a small IPC between `boring` and the proxy — Unix socket or filesystem notify on the registry file; details in §10).

The same-origin payoff: the chat UI at `https://boring.local/marketing-site/` can iframe `https://boring.local/marketing-site/preview/` cleanly — same origin, same cookies, no CSP fights. The marketer sees one URL bar; the proxy hides the multi-service multi-port mechanics underneath.

### 5. TLS via `mkcert` provisioned at install time

`https://` matters even on localhost because:

- Many web APIs (clipboard, notifications, geolocation, service workers for the PWA per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §6) require secure context;
- Mixed-content warnings appear when an `https://` page iframes `http://` content (or vice versa) — the preview iframe needs the same scheme as the chat UI;
- Cookie discipline (Secure, SameSite=Strict) is meaningful only on secure contexts;
- Marketers shouldn't see browser warnings; warnings train them to ignore warnings.

The TLS strategy is `mkcert` ([github.com/FiloSottile/mkcert](https://github.com/FiloSottile/mkcert)) — a tool that installs a local root CA into the system trust store, then issues per-domain certificates trusted by all browsers on that machine.

The install flow:

1. `boring proxy install` checks for `mkcert`; installs it if missing (Homebrew on macOS, package manager on Linux);
2. Runs `mkcert -install` to register the local root CA in the system + browser trust stores (idempotent);
3. Issues a cert for `boring.local` and the wildcard `*.boring.local` (for future per-project subdomains if §4's path-routing is ever replaced; see §10);
4. Configures the proxy to serve TLS using the cert + key, stored at `~/.local/share/boring/proxy/tls/`;
5. Adds `boring.local` to `/etc/hosts` pointing to `127.0.0.1` (the only step that requires `sudo` on the install; happens once).

The cert lifecycle is managed by `mkcert`'s expiry rules (currently 2-3 years per issued cert). Proxy startup checks expiry; if within 30 days of expiry, regenerates automatically (no `sudo` needed for regen; only the initial root CA install needs it). If `mkcert` is unavailable or the install fails, the proxy falls back to `http://boring.local/` with a clear warning at the picker ("TLS not configured; some features unavailable — run `boring proxy install` to fix").

### 6. Authentication: per-user token + Unix-socket isolation

The proxy enforces two layers of access control:

#### 6.1 OS-level isolation (Unix-domain socket between proxy and container backends)

The proxy ↔ in-container communication runs over a Unix-domain socket bound at `$XDG_RUNTIME_DIR/boring/<project-slug>.sock` (or the equivalent path on macOS). The socket is `0600` permissions, owned by the user running boring — other users on a shared laptop cannot reach the socket, regardless of network configuration. The proxy itself is reachable on `boring.local:443` on the loopback interface, but everything *behind* the proxy is gated by the Unix socket's filesystem permissions.

This means: if a malicious user account on the same laptop tries to hit `boring.local`, they reach the proxy but cannot reach any project backend — the socket isn't accessible to them. The browser-to-proxy hop uses TCP (because browsers can't speak Unix sockets); the proxy-to-container hop uses Unix sockets (because security).

#### 6.2 Per-user token in browser cookie

In addition to OS-level isolation, the proxy enforces a per-user token. Flow:

1. First `boring proxy install` generates a random 256-bit token, written to `~/.local/share/boring/proxy/token` (`0600`, owned by the user);
2. First browser visit to `https://boring.local/` reads the token (via a one-time URL parameter the install flow prints: `https://boring.local/auth?t=<token>` or via a local file the proxy serves at `localhost`-only initialization);
3. Browser stores the token in a secure HTTP-only cookie scoped to `boring.local`;
4. Subsequent requests carry the cookie; proxy validates against the on-disk token.

This protects against shared-network attacks where another device on the same Wi-Fi tries to reach `boring.local` if mDNS / hosts-file weirdness ever routes them there. Belt-and-suspenders alongside the Unix-socket isolation.

Token rotation: `boring proxy rotate-token` regenerates the token; all browser sessions need to re-auth. Useful if a laptop is lost (in addition to whatever device-level wipe the user does), or as a periodic hygiene step.

### 7. "Add a project" flow

The "+ Add a project" card in the picker opens a wizard:

1. **Step 1 — Project source.** Two radio buttons: "I have a folder on this Mac" (file picker dialog) or "I want to clone a git repo" (text input for clone URL + target path).
2. **Step 2 — Profile detection.** The wizard checks for `.boring/profile.yaml` in the target path. If present: shows a summary (preset, services, sensitive data flag). If missing: presents two paths — (a) "Pick a preset" (dropdown of curated presets, generates a minimal profile from the chosen preset), or (b) "I'll add the profile myself; let me know when it's ready" (closes the wizard, prompts the marketer to ask an engineer).
3. **Step 3 — Secret URI check.** Walks the profile's `env:` block, finds any `secret://` URIs, and reports which secret-resolver tools (op, vault, etc.) the marketer needs to be authenticated to. Surfaces missing tools with install/login hints (mirrors `boring doctor` output, but inline in the wizard).
4. **Step 4 — Confirm.** Adds the project to the registry; offers "open now" (runs `boring open` immediately and routes to the chat UI when ready) or "save for later" (adds to picker; marketer opens when convenient).

The wizard reuses every backend code path `boring` already has (`profile_load`, `secret_resolve`, registry update). The browser is purely a UI for what the CLI would otherwise prompt for.

### 8. Auto-shutdown of idle containers

Always-running proxy + on-demand containers is fine; always-running *containers* would be wasteful. The proxy tracks browser activity per project; when a project's container has had no browser activity for N hours (default `2h`), the proxy runs `boring close` to free the container's resources.

The timeout is configurable:

- Per profile: `idle_shutdown: 4h` (or `never` to disable);
- Per user in proxy settings (overrides the profile default);
- The default 2h is chosen for "marketer takes a long lunch and comes back" tolerance without pinning resources overnight.

The shutdown UX in the picker:

- The card shows "💤 Stopped — Will resume when you click" with no scary warning;
- Click → "Starting…" loading state → routing as normal;
- The chat thread (per sub-ARD-0022 §1's single-thread-per-project model) is restored from the container volume on next start — auto-shutdown doesn't lose conversation history.

Resource pressure: if the user opens multiple projects concurrently, no automatic eviction; the user is treated as adult enough to close projects they're not using (the picker has a "close" action per card). v1.x doesn't try to be a multi-container scheduler; v1.x+ revisits if real users hit OOM frequently.

### 9. The proxy is a single Go binary (or Caddy with custom config); not Node, not Python

The proxy is built as a single Go binary, distributed alongside `boring` and the preset templates. The single-binary path matters for:

- **Distribution simplicity** — one file copied into `/usr/local/bin/boring-proxy` (or equivalent) at install time; no Python venv, no Node `npm install` dance;
- **Low resource footprint** — Go's idle memory is small; the proxy can sit at single-digit MB and still serve responsively;
- **Cross-OS portability** — same Go source compiles to macOS, Linux, Windows binaries from the same CI workflow;
- **Lifecycle simplicity** — `launchctl load`/`systemctl start` work the same whether the binary is one file or many.

Caddy is the strong alternative: it's a mature HTTPS-by-default reverse proxy with a config-file interface. It's slightly heavier (single binary too, but tens of MB; idle around 30-40 MB), and "Caddy with a custom config plus the boring-ui-specific logic for picker rendering, registry watching, and `boring open` invocation" ends up roughly the same complexity as "small Go binary." If a maintainer with strong Caddy preference picks it up, that's a reasonable substitution; the requirements are config-not-code.

Not Node (would require shipping a Node runtime, adds ~50 MB and a lot of supply-chain surface for a process that just forwards HTTP). Not Python (same concern). Not a Bash script wrapping `socat` or similar (no TLS termination, no routing logic, no service worker for the picker).

### 10. v1.x scope: path-routing only; subdomain routing deferred

Path-routing (`boring.local/<project-slug>/`) is what v1.x ships. Subdomain routing (`marketing-site.boring.local/`, `help-center.boring.local/`) is an obvious-looking alternative but is deferred for three reasons:

- Subdomains require wildcard DNS resolution to `127.0.0.1`. `mkcert` handles the TLS for wildcards; `/etc/hosts` does not handle wildcards (requires per-subdomain entries). The pure-`/etc/hosts` path forces engineers to add a new line every time a project is added — fragile and irritating.
- Workarounds (dnsmasq, mDNS, a local DNS resolver) all add install complexity that v1.x doesn't need to pay.
- Path-routing covers the iframe-the-preview same-origin case (the load-bearing requirement) without subdomain pain.

v1.x+ may add subdomain support behind a feature flag if users with many projects find path-routing unwieldy. Until then, path-routing is the v1.x answer.

Per-session WebSocket / SSE multiplexing: a single proxy listens on `:443`; per-project event streams are multiplexed by path. The chat UI's event stream is at `wss://boring.local/<project-slug>/api/events`; the proxy forwards to the per-container Unix socket. Standard reverse-proxy mechanics, nothing special.

## Consequences

### Positive

- **The marketer never types a command after install.** Open the bookmark, click a project, the proxy + boring + container does everything. The "non-engineer surface" thesis from [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) holds end-to-end.
- **Iframe-the-preview works cleanly** because the chat UI and the preview are on the same origin. No CSP fights, no cookie scoping pain, no mixed-content warnings.
- **Multi-project workflow is first-class.** The picker is the canonical view of "what marketers can work on"; switching projects is a click; the URL is human-shaped (`boring.local/marketing-site/`) instead of port-number-shaped.
- **TLS-by-default** means service workers (PWA support per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §6), notifications, and any future modern-web-API work just work without per-feature workarounds.
- **OS-level isolation** via Unix sockets means the security model survives shared-laptop scenarios. A second user account on the same Mac cannot reach another user's containers, regardless of network configuration.
- **The single-binary proxy is distribution-simple.** No runtime, no install ceremony beyond "copy the binary"; works the same on every supported OS.
- **Auto-shutdown of idle containers keeps resource use bounded.** Always-running proxy + on-demand containers is the right asymmetry for a tool that's used in bursts.
- **Stateless proxy + persistent on-disk state** means the proxy can be killed/restarted/upgraded freely. No "now you have to reauth all your sessions" surprise.

### Negative

- **The always-running proxy is the first persistent host-side process boring adds.** Today boring runs only when invoked; the proxy changes that. Single-digit MB idle is small but nonzero. Users who object to "another always-running thing" have a legitimate complaint. Mitigation: the proxy can be installed without autostart (manual `boring proxy serve`) for users who prefer that.
- **`/etc/hosts` edit at install requires `sudo`.** One-time, scripted, but a `sudo` prompt early in the install is friction. Mitigation: documented clearly; doesn't recur after install.
- **`mkcert` adds a dependency** the user has to install (or the install script installs for them). If `mkcert` is unavailable, falls back to HTTP with reduced functionality (no PWA, no notifications, no service workers).
- **Path-routing means every project URL starts with `boring.local/<slug>/`** — not as elegant as a subdomain per project. Mitigation: deferred subdomain support tracked as v1.x+ work.
- **The proxy is new code we have to write and maintain.** Even as a single Go binary, this is real engineering and ongoing security responsibility. Mitigation: scope kept tight (proxy does *only* TLS-terminate, route, render-picker, watch-registry — no auth-server, no caching layer, no application logic).
- **Auto-shutdown can surprise marketers** ("I came back after 3 hours and my project was stopped"). The UX makes this benign (one click resumes) but it's a moment of friction the first time. Mitigation: surface the timeout clearly in project settings; default value (2h) tuned for the long-lunch case.
- **Single point of failure on the host.** If the proxy crashes, all marketer access stops until launchd/systemd restarts it. Mitigation: keep the proxy simple (few moving parts → few crash sources); launchd/systemd auto-restart on exit; the proxy logs crashes prominently for postmortem.

### Neutral

- **No support for Windows in v1.x.** Deferred alongside the rest of Windows support. Linux + macOS users have full autostart; Windows users on v1.x run the proxy manually.
- **No remote access** (your laptop only). v1.x is local-only by design — no tunnels, no port-forwarding, no remote-access UI. v1.x+ may add `boring share` as an explicit opt-in feature; v1.x does not.
- **No team-wide proxy** (each user has their own). v1.x is one-marketer-per-laptop; multi-user-on-one-laptop (shared family Mac) is the only multi-user case, and the per-user Unix-socket isolation handles it cleanly.
- **Path-routing makes URLs longer** than subdomain routing would. Marketer bookmarks `boring.local/` (the picker), not individual project URLs — the longer path matters less because it's clicked-through, not typed.

## Alternatives Considered (rejected)

- **Forward-port-only routing (no proxy).** Rejected per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §4: port numbers are not memorable, no TLS, cookie scoping awkward, and worst — iframe-the-preview fails because chat UI and preview end up on different origins. The whole iframe UX collapses without same-origin, and same-origin requires the proxy.
- **Cloudflare Tunnel / Tailscale / ngrok as the default browser path.** Rejected per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md): external dependency, latency, account/billing surface, defeats the local-only thesis. May land as v1.x+ opt-in `boring share` subcommand; not the v1.x default.
- **On-demand proxy started by `boring open`.** Rejected: the marketer would have to run `boring open` (a terminal command) once per session, which is exactly the failure mode boring-ui is trying to remove. Always-running is the cost of "no terminal for the marketer."
- **Subdomain routing (`marketing-site.boring.local`) in v1.x.** Rejected per §10: requires wildcard DNS resolution beyond `/etc/hosts` capability; install complexity not worth the URL-aesthetics win. Path-routing covers the load-bearing requirement (same-origin iframe) without the DNS-resolver dependency.
- **Caddy with a custom config (instead of a Go binary).** Not rejected exactly; named as an acceptable substitution if a maintainer wants to use Caddy. The choice is one-vs-the-other ergonomics, not a load-bearing decision. Default to the Go binary for distribution simplicity; substitute Caddy if it ends up easier to author and maintain.
- **Node/Express or Python/FastAPI proxy.** Rejected: shipping a Node or Python runtime for a proxy that just forwards HTTP is a 50+ MB install penalty and a much larger supply-chain surface than the work demands. Go single-binary or Caddy is the right tool for the task.
- **Skip TLS; serve HTTP.** Rejected: blocks PWA installation, service workers, modern web APIs, and looks insecure to anyone who notices the URL bar. mkcert makes TLS-on-localhost a solved problem; skipping it would be defaulting to the worse choice.
- **Per-user proxy on a non-loopback port.** Rejected: increases attack surface, requires firewall rules per-OS, and exposes the proxy to anything on the local network. Loopback-only is correct; remote access is an explicit opt-in for v1.x+, not a default.
- **Skip per-user token; rely only on Unix socket isolation.** Rejected: the Unix socket protects against other user accounts on the same machine, but not against another *device* on the same network if mDNS or hosts-file weirdness ever routes them to `boring.local`. The token is belt-and-suspenders for the cross-device case, cheap to implement, and avoids a category of accidental access.
- **Skip the project picker; show a list at `boring.local/` of clickable project names.** Rejected as an aesthetic regression; the picker is the canonical marketer experience and deserves the design effort. A bare list is the v0 fallback only.
- **Auto-evict the oldest container when starting a new one (active resource scheduling).** Rejected for v1.x: treat the user as adult enough to close projects they're not using; if real users hit OOM frequently with multiple projects open, v1.x+ revisits.

## Implementation Order

1. **`boring proxy` subcommand surface.** Add `boring proxy install`, `boring proxy uninstall`, `boring proxy serve`, `boring proxy status`, `boring proxy rotate-token` to the existing CLI. Stubs first; behavior in subsequent steps.
2. **Single-binary Go proxy: minimum-viable reverse proxy.** TLS termination with mkcert-issued certs; loopback bind on `:443`; path-prefix routing from `boring.local/<slug>/` to per-project Unix sockets; static asset serving for the picker HTML/JS/CSS. Tested against a single hand-crafted backend.
3. **Project picker UI.** Static HTML/JS/CSS bundled into the proxy binary (Go's `embed` package). Reads the registry, renders cards, handles click-to-start. Uses the existing `~/.local/share/boring/registry.json` schema with the addition of a few proxy-managed fields (last-active-at, current-status-string).
4. **`boring open` integration.** The picker's "click to start" sends an IPC message to `boring` (via a small Unix socket or a CLI invocation) to run `boring open <project-path>`. boring registers the container's per-service ports back with the proxy on success; proxy updates its routing table.
5. **mkcert-based TLS provisioning.** `boring proxy install` installs mkcert (Homebrew/package manager), runs `mkcert -install` (the sudo-requiring step), issues `boring.local` + `*.boring.local` certs, writes them to `~/.local/share/boring/proxy/tls/`. Cert expiry checked at proxy startup; regen if within 30 days.
6. **`/etc/hosts` entry on install.** `boring proxy install` adds `127.0.0.1 boring.local` to `/etc/hosts` (sudo'd; idempotent — checks before adding). Documented as the one sudo step.
7. **Per-user token + cookie auth.** Token generated at install, stored at `~/.local/share/boring/proxy/token` (0600). First-visit auth handshake (URL parameter or localhost-served bootstrap page) sets the cookie. Proxy validates on every request.
8. **launchd / systemd autostart registration.** `boring proxy install` writes the LaunchAgent plist (macOS) or systemd unit (Linux) and loads it. `boring proxy uninstall` reverses cleanly.
9. **Multi-project routing table.** Proxy watches the registry for changes (inotify on Linux, FSEvents on macOS) and updates its routing table. Project added → new path becomes routable; project removed → path 404s; `boring close <project>` → path returns a "stopped" page with a "start now" button.
10. **Auto-shutdown of idle containers.** Proxy tracks last-browser-activity-at per project; background goroutine runs `boring close` after the configured idle timeout. Activity = any HTTP request to the project's path, with the chat-event-stream connection counting as continuous activity.
11. **"Add a project" wizard.** Multi-step UI in the picker. Drives the existing `boring` profile-load and registry-update code paths via the same IPC as step 4.
12. **`boring doctor` integration.** New checks: proxy installed; proxy running; mkcert root CA installed; cert valid + not near expiry; `/etc/hosts` entry present; token file present + 0600. Red checks include actionable remediation hints per the existing doctor pattern.
13. **v1.x release artifact.** Single-binary proxy compiled for darwin-arm64, darwin-amd64, linux-amd64, linux-arm64. Shipped alongside the `boring` binary; install scripts updated; install docs updated to walk through the `boring proxy install` flow.

Steps 1-2 can begin in parallel with sub-ARD-0020's harness verification. Steps 3-12 block on the proxy reverse-proxy core (step 2). Step 13 lands at v1.x release.
