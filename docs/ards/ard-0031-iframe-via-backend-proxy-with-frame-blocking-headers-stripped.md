# ARD-0031: Iframe-via-backend-proxy strips `X-Frame-Options` + CSP `frame-ancestors` for the boring-ui preview pane

- **Status:** Accepted (partially amended) — §1's `/preview/*` same-origin sub-path mount is **superseded by [ARD-0033](ard-0033-preview-iframe-on-dedicated-origin.md)** (real upstreams emit root-absolute URLs that escape a sub-path; the preview now runs on its own origin/port). The header-strip mechanism (§2) and safety boundary (§Rationale) are retained.
- **Date:** 2026-05-26
- **Type:** Mini-ARD
- **Extends:** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §1 (preview pane), [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §6 (preview URL resolution), [ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) (proxy responsibilities — explicitly NOT growing them here)

## Context

Confirmed empirically tonight while testing `boring open --ui ~/code/shop-theme`: the Shopify storefront + theme-dev passthrough sets `X-Frame-Options: DENY` on its responses. That header **blocks iframe embedding at the browser level** regardless of iframe origin. The marketer hits the chat URL, the right pane tries to iframe `http://127.0.0.1:9292/`, the browser refuses to render anything, the iframe is blank.

This isn't unique to Shopify. Most production-shaped sites (and many CLIs that proxy real production routes through their local dev server) send `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'` as a clickjacking defense. boring-ui's "live preview alongside chat" UX is **structurally broken** for any such upstream until the headers are stripped.

[ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §1 named the embedded preview as core to the marketer UX promise ("chat on left, preview on right"). Open-in-new-tab is the trivial fallback but defeats the actual product story. The real fix has to make the iframe render.

## Decision

### 1. boring-ui-backend gains a `/preview/*` reverse-proxy route

`tools/boring-ui-backend/server.go` mounts a new route at `/preview/...` that reverse-proxies to the configured `PreviewURL` (`--preview-url` flag value). The chat-UI HTML's iframe `src` changes from the absolute `PreviewURL` to relative `/preview/` — same-origin with the chat page, eliminating cross-origin cookie/auth concerns alongside the framing fix.

```
Browser → http://127.0.0.1:8090/<slug>/                  → chat UI HTML
        → http://127.0.0.1:8090/<slug>/preview/...       → reverse-proxied to PreviewURL with headers stripped
```

### 2. `ModifyResponse` strips two header classes

- **`X-Frame-Options`**: deleted entirely. Single header, single value (`DENY` / `SAMEORIGIN` / etc.), no nuance — just remove it.
- **`Content-Security-Policy`**: scrubbed of the `frame-ancestors` directive ONLY. Other directives (`script-src`, `style-src`, `default-src`, etc.) are preserved because they protect against real XSS/injection risks the marketer's dev preview should keep. If after stripping `frame-ancestors` the CSP becomes empty, drop the whole header.

`Cross-Origin-Resource-Policy`, `Cross-Origin-Opener-Policy`, `Cross-Origin-Embedder-Policy` are **NOT** stripped at v0.10.0 — they govern different cross-origin contexts and don't usually block iframes by themselves. If field evidence shows them blocking real previews, revisit.

### 3. NOT in boring-proxy

boring-proxy (ARD-0021) routes Unix-socket backends only. Growing it to support TCP backends + per-project preview-URL lookup from the registry + response-header rewriting would be substantial scope expansion to a component whose responsibility is "route browser to per-slug Unix sockets" — period. boring-ui-backend, by contrast, already knows the per-project preview URL via `--preview-url`, runs per-project, and is the natural home for per-project-specific behavior. Adding a route handler there is ~50 LOC versus a TCP-routing-class rewrite in boring-proxy.

This also keeps boring-proxy's security profile clean: stripping `X-Frame-Options` is a security-relevant action; concentrating it in the per-project backend (rather than the top-level proxy that serves ALL projects) makes the blast radius of any future bug smaller.

### 4. WebSocket upgrade for HMR is preserved

Go's `httputil.ReverseProxy` handles WebSocket upgrade automatically when both client and upstream send the right headers. Vite, Next, Rails (Hotwire), and Shopify theme-kit all use WS for HMR; the proxy must not break this. Smoke test asserts WS upgrade works end-to-end against a tiny mock echo server.

### 5. URL rewriting in response bodies is NOT attempted

If an upstream's HTML/JS/CSS contains hardcoded absolute URLs (e.g. `http://127.0.0.1:9292/assets/foo.js`), those are NOT rewritten. The browser will fetch them directly, bypassing the proxy. For most modern frameworks this is fine because assets are referenced relatively (`/assets/foo.js`), and the relative paths get proxied through correctly. For frameworks that emit absolute URLs, this is a documented limitation; users can override `preview_url:` to a path the upstream cooperates with.

## Rationale

**Why bypass security headers at all.** The marketer is iframing THEIR OWN local dev server output — not a third-party site. The clickjacking threat `X-Frame-Options` defends against doesn't apply: there's no attacker tricking the marketer into framing a malicious site here; the marketer is explicitly opening their own boring-ui to see their own dev preview. Stripping the header is contextually safe **for this specific use case** in a way it would not be for a general-purpose proxy.

**Why same-origin matters beyond just X-Frame-Options.** Modern web has accumulated several iframe-hostile mechanisms (CSP `frame-ancestors`, `X-Frame-Options`, Strict-Transport-Security cookie scoping, `SameSite=Strict` cookies, the credentialed-fetch tightening from 2026's spec churn). Putting the iframe on the same origin as the chat UI dodges all of them in one shot. The marketer's session for chat + preview becomes one cookie jar, one CORS scope, one origin. Future features (preview link sharing, multi-tab preview, dev-tools integration) all get simpler.

**Why per-project, not top-level.** A future config option could let a profile DISABLE header stripping ("trust the upstream's framing rules") — that's a per-project decision, naturally owned by the per-project boring-ui-backend.

## Consequences

### Positive

- **Iframe renders for `X-Frame-Options: DENY` upstreams.** Shopify, GitHub Codespaces-style dev URLs, any production-shaped site iframe-blocking by default.
- **Same-origin chat ↔ preview** removes a whole class of future cross-origin pain.
- **boring-proxy's responsibility stays sharp** — slug routing, period. No TCP backend support, no per-project response munging, no registry-driven config.
- **Frame-ancestors-only CSP scrubbing** preserves other useful protections (XSS, mixed-content, etc.).
- **WebSocket upgrade preserved** — HMR keeps working.

### Negative

- **Stripping security headers is generally dangerous.** Concentrating it in boring-ui-backend (per-project, local-dev-only context) bounds the risk, but anyone copying this code into a different context could regret it. Comment liberally in the strip helper.
- **boring-ui-backend now makes outbound HTTP** to the preview URL — small coupling expansion. Reachability is fine today (backend and preview both run on host loopback), but a future "backend in container, preview in different container" topology would need explicit network bridging.
- **Hardcoded absolute URLs in response bodies aren't rewritten.** Sites that emit them break in subtle ways (some assets load, some don't). Documented limitation; not all frameworks do this.
- **boring-ui-backend now serves the iframe content** which means its uptime is on the critical path for the preview. If backend dies, preview dies. (Today: if backend dies, the chat thread dies too; preview is a smaller marginal cost.)

### Neutral

- **Iframe src migration** from absolute URL to relative `/preview/` is a one-line HTML change.
- **The `--preview-url` flag stays absolute** — backend needs the full URL (scheme + host + port) to know where to forward, even though the iframe sees a relative path.
- **No new CLI surface.** Existing `--preview-url` flag drives everything; users who didn't set it get the existing fallback-message behavior.
- **Profile schema unchanged.** `preview_url:` / `ui.preview_url:` still mean the same thing; they're passed through to the backend, which now ALSO proxies them.

## Alternatives Considered (rejected)

- **Grow boring-proxy to support TCP backends + per-project preview routing + response-header rewriting.** Rejected: substantial scope expansion to a component whose responsibility is intentionally narrow ("route browser to per-slug Unix sockets"). Adding TCP + per-project lookup + response munging blurs boring-proxy's contract and makes its security profile messier. The per-project backend is the right home.
- **Open the preview in a new tab instead of an iframe.** Bulletproof in the framing sense but **defeats the embedded-preview UX** that ARD-0019 §1 promised as the core marketer experience. Acceptable as a documented fallback (the header strip already has `↗ open in new tab` button), but unacceptable as the primary path.
- **Strip the entire `Content-Security-Policy` header instead of just `frame-ancestors`.** Rejected: nukes useful protections (script-src, style-src, etc.) that defend against real risks (XSS in the dev preview itself). Surgical removal preserves everything except the iframe blocker.
- **Ship a browser extension that strips headers.** Rejected: hostile to security; requires user-side install; can't be made the default for marketer users; signal to user that "something fishy" is going on.
- **Have the upstream dev server NOT set X-Frame-Options.** For Shopify specifically, the header comes from Shopify's storefront infra, not the local theme-dev process. Can't be turned off from the local side. Rejected as a real solution; this is the actual problem this ARD exists to address.
- **Strip `X-Frame-Options` only and leave CSP alone.** Tempting (smaller change) but doesn't fully solve the problem: a real upstream may use `CSP: frame-ancestors 'none'` AS WELL AS or INSTEAD OF `X-Frame-Options`. Stripping both is necessary to make the iframe render reliably.
- **Defer until `boring-ui` has its own server-side iframe rendering** (e.g. screenshot service). Rejected: massive scope expansion; defeats live HMR; pulls in headless-browser tech. Reverse-proxy + header strip is the simpler answer.

## Implementation Order

1. **`tools/boring-ui-backend/server.go`**: new `handlePreview(http.ResponseWriter, *http.Request)` that constructs a `httputil.ReverseProxy` to `PreviewURL` with `Rewrite` (strip `/preview` prefix; set Host to upstream's host) + `ModifyResponse` calling `stripFrameBlockingHeaders(*http.Response) error` helper. Mount at `/preview/...` in the server mux.
2. **`tools/boring-ui-backend/server.go`**: new `stripFrameBlockingHeaders` helper. Always `Header.Del("X-Frame-Options")`. If `Content-Security-Policy` is set: split on `;`, drop any directive starting with `frame-ancestors`, rejoin. If result is empty, delete the header.
3. **`tools/boring-ui-backend/assets/index.html`** + `server.go renderIndex`: iframe src changes from the absolute `{{PREVIEW_URL_SUBSTITUTION}}` to relative `/preview/`. Header strip continues to show the absolute URL in the URL-display element so the user knows what's being proxied.
4. **`tools/boring-ui-backend/server_test.go`** + **`tools/boring-ui-backend/preview_test.go`** (new): mock upstream (httptest.Server) that sets `X-Frame-Options: DENY` + `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'`. Assert proxy's response strips X-Frame-Options entirely + keeps `default-src 'self'` while removing `frame-ancestors`. Second test: WebSocket upgrade end-to-end against a mock WS echo server. Third test: backend unreachable → 502 with actionable error body.
5. **VERSION bump 0.9.1 → 0.10.0; CHANGELOG entry.**
6. **Tag v0.10.0; cut GitHub release.**

Step 1+2 are the load-bearing diff (~50 LOC). Step 4's WS test is the trickiest single item but well-trodden in Go (`gorilla/websocket` not needed — stdlib `golang.org/x/net/websocket` or just verify Upgrade handshake at the HTTP layer).
