# boring stack.dockerfile for Immich.
#
# Layers boring conventions onto Immich's own base-server-dev image, which
# already contains the reverse-geocoding data, libvips, libheif, libraw,
# ffmpeg, corepack+pnpm, and the /usr/src/app/{server,web,packages,...}
# directory shape that the NestJS API assumes at runtime.
#
# Using preset: node-postgres won't work for Immich — too many hardcoded
# paths and native deps live in that base image. stack.dockerfile lets the
# example use the right base without pulling Immich into boring's preset
# surface (which is locked to 5 entries per ARD-0014).
#
# Bump IMMICH_BASE_DEV when you sync the clone past a base-image update;
# the tag lives in upstream's server/Dockerfile.dev.

ARG IMMICH_BASE_DEV=ghcr.io/immich-app/base-server-dev:202605051129
FROM ${IMMICH_BASE_DEV}

# Boring's generated devcontainer.json hardcodes remoteUser: "dev" — the
# UID-1000 user the preset Dockerfiles create. stack.dockerfile profiles
# inherit the same expectation, so we recreate that contract here.
# base-server-dev already ships a UID-1000 `node` user (from the upstream
# Node base); we userdel it and recreate as `dev` so devcontainer-cli's
# `exec as dev` succeeds. Mirrors templates/node-postgres/Dockerfile.

# Boring needs: sudo for setup commands that escalate, tini for clean signal
# handling, git for the trust-anchor hook. The base image already has most
# of these but installs are idempotent.
RUN apt-get update --allow-releaseinfo-change \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git sudo tini iptables iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Create the `dev` user that devcontainer-cli will exec as. Match boring's
# node-postgres preset: UID 1000, NOPASSWD sudo, /bin/bash login shell.
RUN userdel -r node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd --gid 1000 dev \
 && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev

# Trust-anchor pre-commit hook (ARD-0006): refuse commits that touch
# .boring/ from inside the container. Identical body to the preset
# Dockerfiles. boring sets core.hooksPath to the bind-mounted runtime dir
# at /workspace/.devcontainer/boring-runtime; this file is the fallback
# the runtime dir re-exports.
RUN mkdir -p /etc/boring/git-hooks \
 && printf '#!/bin/sh\nset -e\nif git diff --cached --name-only | grep -q "^\\.boring/"; then\n  echo "[boring] refusing to commit changes to .boring/ from inside the container." >&2\n  echo "         .boring/profile.yaml is the trust anchor (ARD-0006). Edit it on the HOST." >&2\n  exit 1\nfi\n' \
      > /etc/boring/git-hooks/pre-commit \
 && chmod +x /etc/boring/git-hooks/pre-commit \
 && git config --system core.hooksPath /workspace/.devcontainer/boring-runtime

# Boring runtime PATH: boring-runtime/bin/ contains command wrappers that
# enforce forbid_commands: (ARD-0009). Sourced for login shells.
RUN printf 'export PATH="/workspace/.devcontainer/boring-runtime/bin:$PATH"\n' \
      > /etc/profile.d/boring-path.sh \
 && chmod 0644 /etc/profile.d/boring-path.sh

# /usr/src/app is hardcoded throughout Immich's server code (upload paths,
# bin paths in PATH, package.json scripts). boring bind-mounts the host
# clone at /workspace, so we symlink /usr/src/app -> /workspace at image
# build time. The base image's empty /usr/src/app directory is replaced.
# Setup chain re-links idempotently in case the bind-mount lands on top.
RUN rm -rf /usr/src/app && ln -s /workspace /usr/src/app

# Match boring's other presets: workdir is the bind-mounted repo root.
WORKDIR /workspace

# Boring's audit collector (ARD-0010) expects to write to this FIFO path,
# which the compose generator bind-mounts from the host. The directory
# must exist; the FIFO itself is created by the audit collector.
RUN mkdir -p /var/log/boring && chmod 0755 /var/log/boring

# Claude Code is installed globally so the in-container agent can run.
# Boring-runtime injects merged settings per ARD-0009; the .claude dir
# under dev's home is where the runtime symlinks settings.json to.
#
# pnpm is installed via npm rather than corepack: the base image sets
# COREPACK_HOME=/tmp and the shims aren't on /usr/local/bin, so corepack's
# pnpm isn't visible to non-login shells (postCreateCommand uses /bin/sh,
# not a login shell). Pin to the version Immich's mise.toml ships.
RUN npm install -g @anthropic-ai/claude-code pnpm@10.33.4 \
 && npm cache clean --force \
 && mkdir -p /home/dev/.claude \
 && chown -R dev:dev /home/dev/.claude
