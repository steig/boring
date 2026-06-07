# ARD-0035: boring-ui preview — multi-tab + editable address bar

- **Status:** Accepted
- **Date:** 2026-06-07
- **Deciders:** Tom (Claude facilitating)
- **Implements:** [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §6 — the `preview_urls:` tab strip promised there but never wired downstream.
- **Builds on:** [ARD-0033](ard-0033-preview-iframe-on-dedicated-origin.md) (dedicated-origin preview proxy), [ARD-0005](ard-0005-security-model-inversion.md) (containment), [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) (profile is the trust anchor).

> **Numbering caveat:** in-flight codex work on another checkout may also have claimed ARD-0035. If so, renumber one before merge.

## Context

The boring-ui preview pane was a single fixed iframe with a **read-only** URL bar. `preview_urls:` (plural) existed in the profile schema + normalization (ARD-0022 §6 promised a tab strip) but was **dead** — `cmd_open`, `lib/web_ui.sh`, and the Go backend were all single-preview. Two asks: let the user change the previewed URL from the UI, and show multiple preview tabs.

## Decision

1. **Multiple declared tabs.** `preview_urls: [{name,url}]` renders one tab per entry. Each tab gets its **own dedicated-origin reverse proxy** (ARD-0033 requires root-mount per origin), on its own host port. Wire format host→backend: `--preview-urls "name=port=upstream,…"` (mutually exclusive with the singular `--preview-url`/`--preview-port`, which folds to a one-element `default` tab). Ports are host-allocated in `lib/web_ui.sh` (`web_ui_preview_urls_arg`, deterministic `cksum("slug:name")` in 8700–9199, linear-probe on collision). A bad upstream or bind collision disables just that tab.

2. **Editable address bar = same-origin navigation only.** Typing a path/URL navigates within the tab's *configured* proxy origin: the frontend applies only `path+query+hash` and **ignores any host the user types**. The frame-stripping proxy stays pinned to declared upstreams — it never becomes an open proxy (ARD-0005 containment). To preview a different site, declare it as a tab.

3. **Runtime tabs reuse allowed origins only.** A `+` button clones the active tab's proxy origin into a new frontend-only tab (path-navigable, closable with `×`); a `×` closes it. Runtime tabs never create a new backend proxy or target an undeclared origin, and are **session-only** (not persisted across reload, and never written to `.boring/` — ARD-0006). Only the active *declared* tab is remembered (localStorage).

## Consequences

- **Positive:** finishes ARD-0022 §6; multi-server dev (e.g. app + docs) and route-hopping work from the UI; the URL bar is useful without weakening containment.
- **Negative:** N proxy listeners instead of one (small, lazy per tab). Runtime tabs don't survive reload (declared tabs are the durable set) — a documented v1 limitation, not a bug.
- **Neutral:** the single-preview path is preserved as a one-tab render (`default`).

## Alternatives considered

- **Arbitrary-URL address bar (browser-style):** rejected — would turn the frame-stripping proxy into an open proxy reachable from the host (SSRF / containment bypass), against ARD-0005.
- **Runtime tabs to new origins (dynamic backend proxies):** rejected for the same containment reason; runtime tabs reuse declared origins instead.

## Implementation

- Backend (`tools/boring-ui-backend/`): `parsePreviewURLs` (`policy.go`), `PreviewTab` + multi-tab `renderPreviewPane` (`server.go`), per-tab listeners (`main.go`).
- Host: `web_ui_preview_urls_arg` + `--preview-urls` plumbing (`lib/web_ui.sh`); `cmd_open` builds the `name=upstream` list from normalized `.preview_urls[]` (`boring`).
- Frontend (`assets/`): tab strip, editable bar (same-origin nav), per-origin nav-reflection routing, runtime add/close (`chat.js`); tab + input styles (`chat.css`).

## Verification

`go test -race ./...` (backend: `parsePreviewURLs` + multi-tab render), `scripts/test.sh` (web-ui smoke asserts `web_ui_preview_urls_arg`), `node --check chat.js`. End-to-end: a profile with two `preview_urls:` entries → `boring open --ui .` → two tabs, switch, edit bar to navigate, `+`/`×` runtime tabs.
