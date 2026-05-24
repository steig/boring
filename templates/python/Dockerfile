# boring preset: python
# Pure Python (uv-based) sandbox for FastAPI/Flask/ML/data/scripts work.
# Mirrors django-node's structure (dev user 1000, NOPASSWD sudo, xdg-open
# shim, ARD-0006 trust-anchor enforcement) minus the Node and libpq layers.
# Single-service compose, no sidecars (a profile can add its own via services:).
#
# Versioning (ARD-0014): toolchain versions are ARGs with v1.0 defaults. A
# profile that needs different versions overrides them via `preset_version:`
# (lib/compose.sh translates that into `--build-arg KEY=value` per service).
ARG PYTHON_VERSION=3.14
FROM python:${PYTHON_VERSION}-slim-bookworm

# UV_VERSION is the Astral installer version, pinned for reproducibility.
ARG UV_VERSION=0.11.6

# System deps + GitHub CLI apt, all in one layer to keep the image lean.
#
# Why these: ca-certificates/curl/gnupg are needed to add the gh apt repo.
# git for git ops. sudo so the dev user can elevate (required for
# `sudo touch /var/lib/boring/setup-complete` in ARD-0007's setup: marker).
# tini reaps zombies and forwards signals so devcontainer exec into us is
# clean. build-essential is here because some Python wheels (cryptography
# etc.) still occasionally need it; cheap insurance vs. mysterious uv-sync
# failures.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git sudo tini build-essential \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# uv: pinned via UV_VERSION ARG above. We install to /usr/local/bin so it's on
# PATH for every shell. UV_PYTHON_DOWNLOADS=never makes uv use the system
# Python instead of pulling its own managed runtime — matching the
# django-node convention.
ENV UV_PYTHON_DOWNLOADS=never
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv

# Claude Code CLI. The python preset has no global Node runtime, but the
# Claude Code CLI is distributed as a Node tarball; install Node only as a
# build-time tool, then install Claude Code globally and leave npm out of the
# image. (For a project that needs Node at dev time, use preset: node or
# preset: django-node instead.)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Non-root dev user matching host UID/GID 1000 so bind-mounted /workspace is
# writable without chown dance. NOPASSWD sudo so setup: can `sudo touch`
# /var/lib/boring/setup-complete and `apt install` extras at dev time.
RUN groupadd --gid 1000 dev \
 && useradd  --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev

# /workspace is where boring bind-mounts the host repo.
# /home/dev/.config pre-created so host bind-mounts under it don't have Docker
#   create the parent as root.
# /var/lib/boring pre-created and owned by dev so setup: marker writes work
#   (ARD-0007 §5). Saves a sudo on the happy path.
RUN mkdir -p /workspace /home/dev/.config /var/lib/boring \
 && chown -R dev:dev /workspace /home/dev /var/lib/boring

# xdg-open shim. Headless containers have no browser; CLIs that try to spawn
# one (gh auth login, claude auth, etc.) crash with ENOENT and abandon their
# polling loops. The shim makes the spawn succeed silently and prints the URL.
RUN printf '#!/bin/sh\necho "[boring] Open this URL in your host browser: $*" >&2\nexit 0\n' \
      > /usr/local/bin/xdg-open \
 && chmod +x /usr/local/bin/xdg-open

# Trust-anchor enforcement (ARD-0006). The .boring/profile.yaml that defines
# this container must NOT be modifiable from inside the container — letting an
# in-container agent edit its own sandbox definition defeats every other
# guardrail. System-wide git pre-commit hook refuses commits touching .boring/;
# Claude Code permissions deny Edit/Write under /workspace/.boring/** (the
# settings.json lives in claude/ and is COPYd below).
RUN mkdir -p /etc/boring/git-hooks \
 && printf '#!/bin/sh\nset -e\nif git diff --cached --name-only | grep -q "^\\.boring/"; then\n  echo "[boring] refusing to commit changes to .boring/ from inside the container." >&2\n  echo "         .boring/profile.yaml is the trust anchor (ARD-0006). Edit it on the HOST." >&2\n  exit 1\nfi\n' \
      > /etc/boring/git-hooks/pre-commit \
 && chmod +x /etc/boring/git-hooks/pre-commit \
 && git config --system core.hooksPath /etc/boring/git-hooks

# Claude Code defaults baked into the container, shared across all presets via
# the `common` build context (templates/_common/claude/):
#   - settings.json       Trust-anchor deny rules (ARD-0006)
#   - CLAUDE.md           Karpathy behavioral guidelines + boring local rules
#   - skills/grill-me/    /grill-me available to the user inside the container
RUN mkdir -p /home/dev/.claude
COPY --from=common --chown=dev:dev claude/ /home/dev/.claude/

WORKDIR /workspace
USER dev
ENV HOME=/home/dev

# tini reaps zombies and forwards signals correctly when devcontainer execs into us.
ENTRYPOINT ["/usr/bin/tini", "--"]
