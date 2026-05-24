# Getting Started

This page takes you from zero to a working `boring open .` in about ten minutes. It assumes you're on macOS or Linux, and that you have a terminal open.

If you'd rather read the design before you install, the [Architecture Decision Records](ards/index.md) cover every material call in detail. If you just want the pitch, the [home page](index.html) has it.

## TL;DR

```bash
# 1. Install runtime deps.
brew install devcontainer jq yq                       # mikefarah yq, not the Python one
# Orbstack on Mac, or Docker Desktop, or Docker Engine on Linux — pick one.

# 2. Install boring.
git clone git@github.com:steig/boring.git ~/code/boring
export PATH="$HOME/code/boring:$PATH"

# 3. Verify.
boring doctor

# 4. Open a repo that has a .boring/profile.yaml.
cd ~/code/your-app
boring open .
```

If your team's repo doesn't yet have a `.boring/profile.yaml`, the [Anatomy of a Profile](profile-reference.md) page walks through every field with copy-pasteable starter examples. Or copy one of the bundled [examples](https://github.com/steig/boring/tree/main/examples) — `shopify`, `django-node`, `python`, `node`, and `node-postgres` are the curated presets you can crib from.

## What you'll need on the host

These are the runtime dependencies. `boring doctor` reports each one with a status line and a remediation hint, so you don't have to memorize this table.

| Dep | Purpose | Install |
|-----|---------|---------|
| **docker** | Container runtime. Orbstack is the recommendation on Mac (near-native FS perf, fast). | <https://orbstack.dev>, or Docker Desktop, or `apt-get install docker.io` on Linux. |
| **devcontainer** | `@devcontainers/cli` — the actual container-lifecycle layer boring delegates to. ([ARD-0003](ards/ard-0003-devcontainer-cli-as-runtime-dependency.md)) | `npm i -g @devcontainers/cli` |
| **dbx** | Backups + the dbx vault, used for secret resolution and real-shape data restores. boring owns zero secret storage; dbx is a runtime dependency. ([ARD-0002](ards/ard-0002-dbx-as-runtime-dependency.md)) | `curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh \| bash` |
| **jq** | JSON for compose generation, `devcontainer.json` synthesis, audit log inspection. | `brew install jq` / `apt-get install jq` |
| **yq** | YAML for profile parsing. **Must be the mikefarah Go variant**, not the Python one. | `brew install yq` |

Optional, only if your profile uses the matching `secret://` URI scheme:

| CLI | URI scheme it enables | Install hint |
|-----|-----------------------|--------------|
| `op` | `op://` (1Password) | `brew install 1password-cli` |
| `vault` | `vault://` (HashiCorp Vault) | `brew install vault` |
| `aws` | `aws-sm:` (AWS Secrets Manager) | `brew install awscli` |
| `security` | `keychain:` on macOS | Preinstalled. |
| `secret-tool` | `keychain:` on Linux (libsecret) | `apt-get install libsecret-tools` |

You only need the CLIs your profile's secret URIs actually reference. `boring doctor` will tell you which ones, in language a non-engineer can act on.

## Install boring itself

The repo is **private during v0 development**. Access is by invite while Tom personally helps the first team members install. Email <tom@steig.io> for an invite.

Once you have repo access:

```bash
git clone git@github.com:steig/boring.git ~/code/boring
export PATH="$HOME/code/boring:$PATH"
echo 'export PATH="$HOME/code/boring:$PATH"' >> ~/.zshrc   # or ~/.bashrc
```

A one-line `curl | bash` installer (`install.sh` at the repo root) lands when the repo flips public in the v0.3 slice. The mechanics are already in place.

### Verify the install

```bash
boring doctor
```

Expected output: a tabular status for each dep, all green for the ones your machine actually needs. Optional CLIs your profile doesn't reference are reported as not-installed-but-fine.

If anything is red, `boring doctor` prints the install command for that dep. Re-run after each fix until green.

## Your first profile

A `.boring/profile.yaml` lives at the **root of the repo you want to open**, not in your home directory. The simplest possible profile is:

```yaml
# .boring/profile.yaml
profile_version: "1"
name: hello-world
preset: python      # or: node, node-postgres, django-node, shopify
```

Drop that into any repo, run `boring open .`, and you'll get an isolated dev container with Python 3.14, `uv`, Claude Code, and your repo bind-mounted at `/workspace`. No sidecars, no setup commands, nothing surprising — just an isolated environment.

The next-most-useful profile adds a forwarded port and a setup command:

```yaml
# .boring/profile.yaml
profile_version: "1"
name: my-app
preset: python

forward_ports: [8000]

setup:
  - uv sync --dev
```

Now `boring open .` will additionally run `uv sync --dev` after the container comes up (idempotent — re-runs only if the success marker is missing) and forward host `:8000` to container `:8000`.

For a profile with a Postgres sidecar, secret URIs, and `setup:` commands that depend on the sidecar being ready, see [Anatomy of a Profile](profile-reference.md). Every field is documented there with a working example.

## What `boring open` actually does

Operationally, `boring open .`:

1. **Parses** `.boring/profile.yaml` and validates it against the schema. Errors on unknown fields with an upgrade hint. ([ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md))
2. **Resolves** `secret://` URIs by shelling out to `op`, `security`, `vault`, etc. and capturing values in memory. The values are passed to `devcontainer up --remote-env`. Resolved secrets are **never written** to `docker-compose.yml`, `devcontainer.json`, or any file on disk. ([ARD-0002](ards/ard-0002-dbx-as-runtime-dependency.md))
3. **Generates** `.devcontainer/docker-compose.yml` and `.devcontainer/devcontainer.json` from the profile. Sidecars get auto-wired `depends_on` with healthcheck-aware conditions. Both generated files are gitignored.
4. **Builds + starts** the container via the standard `@devcontainers/cli`. boring does not run `docker compose up` directly. ([ARD-0003](ards/ard-0003-devcontainer-cli-as-runtime-dependency.md))
5. **Runs** `setup:` once after first up via `postCreateCommand`, writes a success marker, and re-verifies the marker post-up. If it's missing (a hook half-failed), boring re-runs the chain. Silence isn't success. ([ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md))
6. **Drops you into the container** with an interactive shell. From there, `code .` attaches VS Code, `claude` opens an in-container Claude Code session, and your forwarded ports are live on `localhost`.

Re-running `boring open .` on the same repo reuses the existing container if the profile hasn't changed. Edit the profile and re-run to apply changes — boring detects the change and rebuilds.

## Common second commands

Once you're in:

```bash
# Inside the container, after boring open .
claude                      # in-container Claude with this project's MCP + memory
code .                      # attach VS Code via the Dev Containers extension
exit                        # leave the container (it keeps running in the background)
```

From the host:

```bash
boring doctor               # re-check host deps
boring restore .            # re-run the restore: chain (v0.5+)
boring audit security <profile-name>     # tail security events (v0.3+)
boring run "<claude-prompt>" --profile <name>   # headless one-shot (v0.6+)
```

The full subcommand list is in `boring help`.

## When something doesn't work

- **`boring doctor` reports red on something:** install the missing dep using the printed command, re-run `boring doctor`. That's the loop.
- **`boring open .` errors on "profile_version missing":** add `profile_version: "1"` to your `.boring/profile.yaml`.
- **Container builds but `setup:` fails:** check the container's logs — `docker compose -f .devcontainer/docker-compose.yml logs dev`. The `setup:` chain ran during `postCreateCommand`; the success marker isn't written, so re-running `boring open .` will retry.
- **Secret resolution fails:** the secret-resolver CLI (e.g. `op`) needs to be authenticated on the host. `op signin` (or the equivalent) before `boring open .`.
- **You change `.boring/profile.yaml` and the change doesn't take effect:** today, the workaround is `cd .devcontainer && docker compose down && cd .. && boring open .`. Auto-recreate-on-profile-change is on the v1.x list.

If you hit something the above doesn't cover, file an issue at <https://github.com/steig/boring/issues> or email <tom@steig.io>.

## Where to go next

- [Anatomy of a Profile](profile-reference.md) — every field in `.boring/profile.yaml`, what it does, what compose primitive it maps to, when to use it.
- [Architecture Decision Records](ards/index.md) — every material design decision, with one-line summaries on the index.
- [Examples](https://github.com/steig/boring/tree/main/examples) — copy-pasteable starter profiles for each preset.
- [Changelog](changelog.md) — what shipped, when, with ARD cross-references.
