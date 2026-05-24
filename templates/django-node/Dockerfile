# boring preset: django-node
# Polyglot stack for Django + React/Vite + Postgres dev (the
# ~/code/work/content-infrastructure shape). Python 3.14 + uv + Node 20 +
# libpq + postgres-client + claude defaults via the `common` build context.
# Mirrors the shopify preset's structure for consistency (dev user 1000,
# NOPASSWD sudo, xdg-open shim, ARD-0006 trust-anchor enforcement).
FROM python:3.14-slim-bookworm

ARG UV_VERSION=0.11.6

# System deps + GitHub CLI apt + Node 20 via NodeSource + libpq + psql client,
# all in one layer to keep the image lean.
#
# Why these: ca-certificates/curl/gnupg are needed to add the gh + nodesource
# apt repos. git for git ops. sudo so the dev user can elevate (required for
# `sudo touch /var/lib/boring/setup-complete` in ARD-0007's setup: marker).
# tini reaps zombies and forwards signals so devcontainer exec into us is
# clean. build-essential is here because some Python wheels (cryptography
# etc.) still occasionally need it; cheap insurance vs. mysterious uv-sync
# failures. libpq5 is psycopg's runtime dep; postgresql-client gives `psql`
# and `pg_isready` for use in setup: hooks (migrate prerequisites, health
# probes from inside the dev container).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git sudo tini build-essential \
      libpq5 postgresql-client \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs gh \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# uv: pinned via UV_VERSION ARG above. We install to /usr/local/bin so it's on
# PATH for every shell, then unset UV_PYTHON_DOWNLOADS at the project level by
# pointing UV_PROJECT_ENVIRONMENT at a project-local .venv (the wrapped repo
# manages this; we just install the tool). UV_PYTHON_DOWNLOADS=never makes uv
# use the system Python 3.14 instead of pulling its own managed runtime,
# matching content-infrastructure's Dockerfile pattern.
ENV UV_PYTHON_DOWNLOADS=never
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv

# Claude Code CLI as a global npm package (current stable channel).
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# Non-root dev user matching host UID/GID 1000 so bind-mounted /workspace is
# writable without chown dance. NOPASSWD sudo so setup: can `sudo touch`
# /var/lib/boring/setup-complete and `apt install` extras at dev time.
RUN groupadd --gid 1000 dev \
 && useradd  --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev

# /workspace is where boring bind-mounts the host repo.
# /home/dev/.config pre-created so host bind-mounts under it don't have Docker
#   create the parent as root (same fix as the shopify preset).
# /var/lib/boring pre-created and owned by dev so setup: marker writes work
#   (ARD-0007 §5). Saves a sudo on the happy path.
# /var/log/boring pre-created for ARD-0010's audit FIFO bind-mount; world-
#   writable so the dev user can write through the FIFO.
RUN mkdir -p /workspace /home/dev/.config /var/lib/boring /var/log/boring \
 && chown -R dev:dev /workspace /home/dev /var/lib/boring \
 && chmod 0755 /var/log/boring

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
#   - settings.json       Trust-anchor deny rules (ARD-0006) + audit hook
#                         entries (ARD-0010 §3) + deny rules for the audit-emit
#                         scripts themselves (ARD-0010 trust-anchor extension)
#   - CLAUDE.md           Karpathy behavioral guidelines + boring local rules
#   - skills/grill-me/    /grill-me available to the user inside the container
RUN mkdir -p /home/dev/.claude
COPY --from=common --chown=dev:dev claude/ /home/dev/.claude/

# ARD-0010 audit-emit binaries: image-baked at /usr/local/boring/bin/. Same
# pattern as the shopify preset — the Claude hooks declared in settings.json
# call the per-kind symlinks; the script derives kind from $0. Owned root so
# the dev user (even with sudo) can't replace via Claude.
COPY --from=common --chown=root:root boring-bin/audit-emit /usr/local/boring/bin/audit-emit
RUN chmod 0755 /usr/local/boring/bin/audit-emit \
 && ln -s /usr/local/boring/bin/audit-emit /usr/local/boring/bin/audit-emit-prompt_issued \
 && ln -s /usr/local/boring/bin/audit-emit /usr/local/boring/bin/audit-emit-tool_used \
 && ln -s /usr/local/boring/bin/audit-emit /usr/local/boring/bin/audit-emit-prompt_completed

WORKDIR /workspace
USER dev
ENV HOME=/home/dev

# 8000 — Django dev server (`uv run python backend/manage.py runserver`)
# 5173 — Vite dev server (`cd frontend && npm run dev`)
# Documentation only; devcontainer wires actual forwarding via forward_ports:.
EXPOSE 8000 5173

# tini reaps zombies and forwards signals correctly when devcontainer execs into us.
ENTRYPOINT ["/usr/bin/tini", "--"]
