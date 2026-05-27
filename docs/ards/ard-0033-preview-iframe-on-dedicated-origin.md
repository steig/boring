# ARD-0033: Preview iframe served on a dedicated origin (port), not a same-origin sub-path

- **Status:** Accepted
- **Date:** 2026-05-26
- **Type:** Mini-ARD
- **Supersedes:** [ARD-0031](ard-0031-iframe-via-backend-proxy-with-frame-blocking-headers-stripped.md) §1 (the `/preview/*` same-origin sub-path mechanism). The header-strip rationale and safety boundary from ARD-0031 §2 / §Rationale are **retained** — only the mount point changes.
- **Extends:** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §1 (preview pane), [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §6 (preview URL resolution)

## Context

ARD-0031 made the preview iframe load a same-origin sub-path (`/<slug>/preview/`) on the
singleton host proxy (`:8090`), reverse-proxying to the configured `--preview-url` with
`X-Frame-Options` + CSP `frame-ancestors` stripped. That shipped in v0.10.0; v0.10.1 fixed a
chat-pane init crash; a follow-up fixed the iframe `src` from root-relative `/preview/` to
page-relative `preview/` (the root-relative form escaped the `/<slug>/` proxy mount and hit the
proxy's own `frame-ancestors 'none'` 404).

Testing `boring open --ui ~/code/shop-theme` end-to-end (Shopify theme dev on `:9292`, real auth)
exposed a **fatal limitation of the sub-path design**:

- `:9292` sets `X-Frame-Options: DENY`, so a proxy that strips it is genuinely required — we cannot
  iframe the upstream directly.
- The Shopify storefront references **every** asset with **root-absolute** URLs:
  `/cdn/shop/t/144/assets/theme.css`, `/cdn/shopifycloud/shop-js/.../*.esm.js`,
  `/checkouts/internal/preloads.js`, `/web-pixels@.../sandbox/...`. Inside an iframe whose document
  is `…:8090/<slug>/preview/`, a root-absolute URL resolves to `…:8090/cdn/...` — it escapes the
  `/<slug>/preview/` prefix, hits the shared proxy root, and 404s as `text/plain` with
  `frame-ancestors 'none'`.

Observed: a wall of "Refused to apply style/execute script (MIME 'text/plain')" errors, framing
violations on the web-pixel sandboxes, and a failed ESM import — i.e. the preview is structurally
broken for any upstream that emits root-absolute URLs. A `<base href>` cannot fix this: `<base>`
does not affect root-absolute (leading-slash) URLs. This is exactly the alternative ARD-0031 §5
deferred ("give the preview its own origin").

## Decision

### Serve the preview reverse-proxy on its own origin (a dedicated per-slug port), mounted at root

A second `http.Server` inside `boring-ui-backend` binds `127.0.0.1:<preview-port>` and
reverse-proxies **`/` (root)** to `--preview-url`, stripping the same frame-blocking headers
(`stripFrameBlockingHeaders`, unchanged from ARD-0031). The right-pane iframe `src` becomes the
absolute `http://127.0.0.1:<preview-port>/`.

```
Browser → http://127.0.0.1:8090/<slug>/            → chat UI (host proxy → backend unix socket)
        → http://127.0.0.1:<preview-port>/          → preview proxy (backend TCP listener → upstream)
        → http://127.0.0.1:<preview-port>/cdn/x.css → preview proxy → upstream /cdn/x.css ✓
```

Because the preview is at its own origin **root**, the upstream's root-absolute asset URLs resolve
back into the preview proxy and forward correctly. Cross-origin framing is fine: `X-Frame-Options` /
`frame-ancestors` are enforced on the *framed* (child) response, and the proxy strips them on every
response, so the chat UI can frame the preview origin.

### Mechanics

- **Port:** `web_ui_preview_port <slug>` — deterministic per-slug, range `8700..9199`
  (`8700 + cksum%500`), clear of the ttyd range (`7681..8679`), the host proxy (`8090`), Shopify dev
  (`9292`), and common dev ports. Same slug → same port across re-runs.
- **Flag:** `boring-ui-backend --preview-port <n>`. The listener starts only when both
  `--preview-url` and a non-zero `--preview-port` are set. A bind failure (port collision) logs a
  warning and disables the preview — it does **not** take down the chat UI.
- **Handler:** `newPreviewProxyHandler` (in `preview.go`) — root-mounted, no prefix stripping, query
  string preserved, WebSocket upgrade preserved (Shopify theme hot-reload, Vite/Next HMR).
- **Header display vs. iframe target:** the header strip's URL text + open-in-new-tab link use the
  **upstream** URL (so the user sees/opens the real dev server in a clean top-level tab, which isn't
  subject to `X-Frame-Options`); the iframe `src` is the preview-proxy origin.
- The `/preview/*` sub-path route on the backend mux is **removed**.

## Consequences

- **Address bar can't read the iframe location directly.** Because the preview is now cross-origin, the chat UI can't read `iframe.contentWindow.location` to show "what page am I on." Resolved by injecting a tiny same-origin script (`/__boring_nav.js`, served from the preview origin so it satisfies a `script-src 'self'` CSP) into proxied HTML responses; it `postMessage`s the current path to the chat UI. The script reports **only from the top preview frame** (`window.parent === window.top`), so the upstream's own nested iframes (Shopify web-pixel sandboxes) don't pollute the bar — the discriminator that a pure server-side detector lacks. To inject without decompressing, the proxy strips `Accept-Encoding` outbound (the Go transport then transparently decompresses); for non-Shopify upstreams it also appends `'self'` to any existing `script-src`. Server-side detection via `Sec-Fetch-Dest` was rejected: nested sub-iframe navigations are indistinguishable from top-frame navigations at the proxy.
- **Cross-origin cookies.** The preview iframe is now a different origin from the chat UI. Upstream
  cookies with `SameSite=Lax`/`Strict` (Shopify's `_shopify_*` are `Lax`) are not sent on
  cross-site iframe subrequests, so cart/session state inside the preview may not fully persist
  across in-iframe navigations. Acceptable for a visual dev preview, and unavoidable: the
  same-origin approach is fundamentally incompatible with root-absolute upstream URLs.
  Protocol-relative externals (`//cdn.shopify.com/...`) load from the real CDN directly.
- **Host-backend assumption.** The preview listener binds `127.0.0.1:<port>` on the host where the
  backend runs (current `web_ui_backend_start` behavior), so the browser reaches it directly. If
  the backend is ever moved in-container, that port must be published to the host.
- **Retained from ARD-0031:** the header-strip is still a **local-dev-only** safety boundary — the
  user iframes their own dev server; do not copy `stripFrameBlockingHeaders` into a
  production-facing proxy (it re-enables clickjacking).

## Alternatives rejected

- **Rewrite upstream HTML/JS to inject the prefix.** Infeasible for modern JS apps — root-absolute
  URLs are also constructed at runtime (ESM imports, web-pixel sandboxes, fetch). The dedicated
  origin obviates rewriting entirely.
- **`<base href>` in the proxied HTML.** Does not affect root-absolute URLs; only relative ones.
- **Iframe `:9292` directly.** Blocked: `:9292` sends `X-Frame-Options: DENY`.
