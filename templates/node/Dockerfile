# boring preset: node
# Pure Node sandbox for Express/Next/Vite/Astro (anything that needs Node + npm
# but no Python or DB). Mirrors django-node's structure (dev user 1000, NOPASSWD
# sudo, xdg-open shim, ARD-0006 trust-anchor enforcement) without the Python
# stack. Single-service compose, no sidecars (use preset: node-postgres if you
# want a wired-in Postgres sidecar; a profile can also add its own via services:).
#
# Default is Node (not bun) per the v1.0 preset list (ARD-0014). bun ships as a
# separate v1.x preset.
#
# Versioning (ARD-0014): toolchain versions are ARGs with v1.0 defaults. A
# profile that needs different versions overrides them via `preset_version:`.
ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-bookworm-slim

# System deps + GitHub CLI apt, all in one layer to keep the image lean.
#
# Why these: ca-certificates/curl/gnupg are needed to add the gh apt repo.
# git for git ops. sudo so the dev user can elevate (required for
# `sudo touch /var/lib/boring/setup-complete` in ARD-0007's setup: marker).
# tini reaps zombies and forwards signals so devcontainer exec into us is
# clean. build-essential is here because some npm packages (node-gyp builds,
# native modules) still occasionally need it; cheap insurance.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git sudo tini build-essential \
      iptables iproute2 gosu dnsutils \
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

# Claude Code CLI as a global npm package (current stable channel).
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# Non-root dev user matching host UID/GID 1000 so bind-mounted /workspace is
# writable without chown dance. NOPASSWD sudo so setup: can `sudo touch`
# /var/lib/boring/setup-complete and `apt install` extras at dev time.
#
# The node:*-bookworm-slim base image already ships with a `node` user at
# uid/gid 1000. Delete it first so we can recreate as `dev` for consistency
# with the other presets (and with the convention dev tooling expects).
RUN userdel -r node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd --gid 1000 dev \
 && useradd  --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev

# /workspace is where boring bind-mounts the host repo.
# /home/dev/.config pre-created so host bind-mounts under it don't have Docker
#   create the parent as root.
# /var/lib/boring pre-created and owned by dev so setup: marker writes work
#   (ARD-0007 §5). Saves a sudo on the happy path.
# /var/log/boring is the parent dir for the ARD-0010 audit FIFO bind-mount;
#   pre-create so Docker can land the FIFO at /var/log/boring/events.fifo
#   without conflict.
RUN mkdir -p /workspace /home/dev/.config /var/lib/boring /var/log/boring \
 && chown -R dev:dev /workspace /home/dev /var/lib/boring \
 && chmod 0755 /var/log/boring

# xdg-open shim. Headless containers have no browser; CLIs that try to spawn
# one (gh auth login, claude auth, etc.) crash with ENOENT and abandon their
# polling loops. The shim makes the spawn succeed silently and prints the URL.
RUN printf '#!/bin/sh\necho "[boring] Open this URL in your host browser: $*" >&2\nexit 0\n' \
      > /usr/local/bin/xdg-open \
 && chmod +x /usr/local/bin/xdg-open

# Trust-anchor enforcement (ARD-0006 + ARD-0009). The .boring/profile.yaml
# that defines this container, and the generated artifacts at
# .devcontainer/boring-runtime/ that enforce it, must NOT be modifiable from
# inside the container. core.hooksPath points at the boring-runtime dir
# (bind-mounted RO by the host) where boring writes pre-commit + pre-push
# at `boring open` time. /etc/boring/git-hooks/pre-commit is retained as a
# fallback so the trust anchor still fires when the runtime dir is absent
# (e.g. a stale container without a regenerated runtime dir).
RUN mkdir -p /etc/boring/git-hooks \
 && printf '#!/bin/sh\nset -e\nif git diff --cached --name-only | grep -q "^\\.boring/"; then\n  echo "[boring] refusing to commit changes to .boring/ from inside the container." >&2\n  echo "         .boring/profile.yaml is the trust anchor (ARD-0006). Edit it on the HOST." >&2\n  exit 1\nfi\n' \
      > /etc/boring/git-hooks/pre-commit \
 && chmod +x /etc/boring/git-hooks/pre-commit \
 && git config --system core.hooksPath /workspace/.devcontainer/boring-runtime

# ARD-0009: prepend the boring-runtime command-wrapper dir to PATH for all
# login shells. Wrappers (and the ARD-0010 audit-emit shim + symlinks) are
# generated host-side at `boring open` time and bind-mounted RO; this snippet
# just ensures they shadow the real binaries.
RUN printf 'export PATH="/workspace/.devcontainer/boring-runtime/bin:$PATH"\n' \
      > /etc/profile.d/boring-path.sh \
 && chmod 0644 /etc/profile.d/boring-path.sh
ENV PATH="/workspace/.devcontainer/boring-runtime/bin:${PATH}"

# Claude Code defaults baked into the container, shared across all presets via
# the `common` build context (templates/_common/claude/):
#   - settings.json       Baseline trust-anchor deny rules (ARD-0006) + audit
#                         hook entries (ARD-0010 §3) + deny rules for
#                         settings.json itself. boring's host-side jq merge
#                         layers `permissions.allow` on top per profile
#                         (ARD-0009).
#   - CLAUDE.md           Karpathy behavioral guidelines + boring local rules
#   - skills/grill-me/    /grill-me available to the user inside the container
# After COPY, swap settings.json for a symlink to the boring-runtime mount so
# Claude reads the merged file (ARD-0009). The dangling symlink at image
# build time becomes live once the container starts and the bind-mount lands.
RUN mkdir -p /home/dev/.claude
COPY --from=common --chown=dev:dev claude/ /home/dev/.claude/
RUN rm -f /home/dev/.claude/settings.json \
 && ln -s /workspace/.devcontainer/boring-runtime/claude/settings.json /home/dev/.claude/settings.json \
 && chown -h dev:dev /home/dev/.claude/settings.json

# ARD-0010 audit-emit binaries are NOT image-baked here. They live at
# /workspace/.devcontainer/boring-runtime/bin/audit-emit{,-<kind>}, emitted
# host-side by `boring open` and bind-mounted RO.

# Egress enforcement (ARD-0011). install-egress runs as root at boot, installs
# iptables OUTPUT rules from /etc/boring/egress.allow (RO bind-mount from host),
# then drops to the `dev` user via gosu before execing user code. Noop unless
# BORING_EGRESS_MODE is set — profiles without egress.allow are unaffected.
COPY --from=common --chmod=0755 bin/install-egress /usr/local/boring/bin/install-egress
RUN mkdir -p /etc/boring

WORKDIR /workspace
# Note: no `USER dev` here — install-egress requires root to install iptables
# rules, then `exec gosu dev "$@"` drops privileges before user code runs.
# For profiles without egress.allow, BORING_EGRESS_MODE is unset and
# install-egress is a thin passthrough that still drops to dev via gosu.
ENV HOME=/home/dev

# tini reaps zombies and forwards signals correctly when devcontainer execs into us.
# install-egress is in the entrypoint chain so it runs BEFORE the container
# command — it either installs rules or noops, then execs gosu dev "$@".
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/boring/bin/install-egress"]
