# python preset

Default base image when a profile declares `preset: python`. boring uses this
unless the profile overrides it with `stack: { dockerfile: ... }`.

Target shape: a single-language Python sandbox (FastAPI/Flask/ML/data/scripts)
with uv as the package manager and Claude Code available out of the box. No
sidecars, no Node toolchain, no Postgres client.

## Installed

| Tool          | Version           | Source                          |
|---------------|-------------------|---------------------------------|
| Python        | 3.14 (default; `PYTHON_VERSION` ARG) | `python:${PYTHON_VERSION}-slim-bookworm` |
| uv            | pinned via `UV_VERSION` ARG | Astral installer          |
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

Override the default Python version via `preset_version:`:

```yaml
profile_version: "1"
name: my-py-app
preset: python
preset_version:
  python: "3.12"
```

## Example minimum profile

```yaml
profile_version: "1"
name: my-py-app
preset: python

setup:
  - uv sync --dev
```

See [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
for the preset versioning scheme.

## Overriding

A profile can opt out by declaring `stack.dockerfile`; the preset's defaults
still apply if seeded — only the image changes.
