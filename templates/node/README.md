# node preset

Default base image when a profile declares `preset: node`. boring uses this
unless the profile overrides it with `stack: { dockerfile: ... }`.

Target shape: a single-language Node sandbox (Express/Next/Vite/Astro) with
Claude Code available out of the box. No sidecars, no Python, no Postgres
client. For a Node + Postgres setup, use `preset: node-postgres` instead.

Default is Node, not bun (per ARD-0014). bun is deferred to v1.x as a separate
preset.

## Installed

| Tool          | Version           | Source                          |
|---------------|-------------------|---------------------------------|
| Node.js       | 20 (default; `NODE_VERSION` ARG) | `node:${NODE_VERSION}-bookworm-slim` |
| npm           | bundled with Node | base image                      |
| Claude Code   | current stable    | `@anthropic-ai/claude-code`     |
| git, gh       | bookworm + gh apt | Debian + GitHub apt repo        |
| tini          | bookworm          | Debian apt                      |

## Container shape

- Non-root `dev` (uid/gid `1000`), passwordless `sudo`.
- `/workspace` is the working dir (boring bind-mounts the host repo here).
- `HOME=/home/dev`.
- `/var/lib/boring/` is pre-owned by `dev` for the ARD-0007 setup-complete marker.
- `tini` as PID 1 so devcontainer signal handling is clean.
- ARD-0006 trust-anchor enforcement: in-container git refuses commits touching
  `.boring/`, and Claude Code defaults deny `Edit`/`Write` under `/workspace/.boring/**`.

## Versioning (ARD-0014)

Override the default Node version via `preset_version:`:

```yaml
profile_version: "1"
name: my-node-app
preset: node
preset_version:
  node: "22"
```

## Example minimum profile

```yaml
profile_version: "1"
name: my-node-app
preset: node

forward_ports: [3000]

setup:
  - npm install
```

See [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
for the preset versioning scheme.

## Overriding

A profile can opt out by declaring `stack.dockerfile`; the preset's defaults
still apply if seeded — only the image changes.
