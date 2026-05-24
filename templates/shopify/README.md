# shopify theme preset

Default base image when a profile declares `theme: shopify`. boring uses this
unless the profile overrides it with `stack: { dockerfile: ... }`.

## Installed

| Tool         | Version              | Source                     |
|--------------|----------------------|----------------------------|
| Ruby         | 3.3 (image base)     | `ruby:3.3-slim-bookworm`   |
| Node.js      | 20.x                 | NodeSource apt repo        |
| Shopify CLI  | current stable       | `npm i -g @shopify/cli`    |
| Claude Code  | current stable       | `@anthropic-ai/claude-code`|
| git, gh      | bookworm + gh apt    | Debian + GitHub apt repo   |
| tini         | bookworm             | Debian apt                 |

## Container shape

- Non-root `dev` (uid/gid `1000`), passwordless `sudo`.
- `/workspace` is the working dir (boring bind-mounts the host repo here).
- `HOME=/home/dev`.
- Port `9292` exposed for `shopify theme dev`'s hot-reload proxy.
- `tini` as PID 1 so devcontainer signal handling is clean.
- No `CMD`/`ENTRYPOINT` workload — devcontainer CLI drives it
  (see [ARD-0003](../../docs/ards/ard-0003-devcontainer-cli-as-runtime-dependency.md)).

## Overriding

A profile can opt out by declaring `stack.dockerfile`; the preset's egress and
`mounts:` defaults still apply, only the image changes.

## Drift with project-side Nix flakes

This Dockerfile pins the toolchain a typical Shopify theme dev shell
expects. If your project also pins its tools via `flake.nix` (or
`asdf`, `mise`, etc.), the two definitions must not drift — when the
project pins a new tool or version, add it here in the same change. See
[ARD-0004](../../docs/ards/ard-0004-shopify-first-as-dogfood-path.md).
