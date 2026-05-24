# boring theme preset: shopify
# Toolchain (Node 20, Ruby 3.3, Shopify CLI, git, gh) mirrors what a typical
# Shopify theme dev shell expects. Matches what `flake.nix`-using projects pin.
# Constraint says use node:20-bookworm-slim, but Ruby 3.3 isn't in bookworm apt.
# Picking ruby:3.3-slim-bookworm + NodeSource Node 20 instead: both tools come from
# upstream-official sources, no version managers, both pinned to declared majors.
#
# Versioning (ARD-0014): toolchain versions are ARGs with v1.0 defaults. A
# profile that needs different versions overrides them via `preset_version:`
# (lib/compose.sh translates that into `--build-arg KEY=value` per service).
ARG RUBY_VERSION=3.3
ARG NODE_VERSION=20
FROM ruby:${RUBY_VERSION}-slim-bookworm

# Re-declare post-FROM ARGs we still reference (Docker scopes pre-FROM ARGs
# to the FROM directive only).
ARG NODE_VERSION

# System deps + GitHub CLI repo + Node 20 via NodeSource, all in one layer to keep image lean.
# curl/gnupg/ca-certificates needed to add the gh + nodesource apt repos.
# build-essential is needed for native gem compilation (e.g. theme-check transitive deps).
# sudo is installed so the dev user can elevate inside the container when wanted (not required).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git sudo tini build-essential \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs gh \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Shopify CLI + Claude Code CLI as global npm packages (current stable channel).
# Verified npm package names: @shopify/cli, @anthropic-ai/claude-code.
RUN npm install -g @shopify/cli @anthropic-ai/claude-code \
 && npm cache clean --force

# Non-root dev user matching host UID/GID 1000 so bind-mounted /workspace is writable without chown dance.
RUN groupadd --gid 1000 dev \
 && useradd  --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev

# /workspace is where boring bind-mounts the host repo; pre-create so first-run perms are right.
# /home/dev/.config is also pre-created so that boring's bind-mounts (~/.config/shopify, ~/.config/gh)
# don't cause Docker to create the parent dir as root, which would block sibling CLIs like
# shopify-cli-kit-nodejs (a different config dir under .config/) from writing.
RUN mkdir -p /workspace /home/dev/.config \
 && chown -R dev:dev /workspace /home/dev

# xdg-open shim. Headless containers have no browser; CLIs that try to spawn
# one (shopify auth login, gh auth login, claude auth, etc.) crash with
# ENOENT and abandon their polling loops. The shim makes the spawn succeed
# silently and prints the URL so the user can open it in their host browser.
RUN printf '#!/bin/sh\necho "[boring] Open this URL in your host browser: $*" >&2\nexit 0\n' \
      > /usr/local/bin/xdg-open \
 && chmod +x /usr/local/bin/xdg-open

# Trust-anchor enforcement (ARD-0006). The .boring/profile.yaml that defines
# this container must NOT be modifiable from inside the container — letting
# an in-container agent edit its own sandbox definition defeats every other
# guardrail. System-wide git pre-commit hook refuses commits touching .boring/;
# Claude Code permissions deny Edit/Write under /workspace/.boring/** (the
# settings.json that does this lives in claude/ and is COPYd below).
RUN mkdir -p /etc/boring/git-hooks \
 && printf '#!/bin/sh\nset -e\nif git diff --cached --name-only | grep -q "^\\.boring/"; then\n  echo "[boring] refusing to commit changes to .boring/ from inside the container." >&2\n  echo "         .boring/profile.yaml is the trust anchor (ARD-0006). Edit it on the HOST." >&2\n  exit 1\nfi\n' \
      > /etc/boring/git-hooks/pre-commit \
 && chmod +x /etc/boring/git-hooks/pre-commit \
 && git config --system core.hooksPath /etc/boring/git-hooks

# Claude Code defaults baked into the container, shared across all theme
# presets via the `common` build context (templates/_common/claude/):
#   - settings.json       Trust-anchor deny rules (ARD-0006)
#   - CLAUDE.md           Karpathy behavioral guidelines + boring local rules
#   - skills/grill-me/    /grill-me available to the user inside the container
# When adding new theme presets (django, rails, etc.), copy this RUN+COPY
# pair verbatim — the `common` context is wired up by lib/compose.sh.
RUN mkdir -p /home/dev/.claude
COPY --from=common --chown=dev:dev claude/ /home/dev/.claude/

WORKDIR /workspace
USER dev
ENV HOME=/home/dev

# 9292 is Shopify CLI's theme-dev hot-reload proxy. Documentation only; devcontainer wires forwarding.
EXPOSE 9292

# tini reaps zombies and forwards signals correctly when devcontainer execs into us.
ENTRYPOINT ["/usr/bin/tini", "--"]
