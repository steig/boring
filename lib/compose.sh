#!/usr/bin/env bash
#
# lib/compose.sh — generate docker-compose.yml + devcontainer.json from a parsed profile.
#
# Consumes the normalized JSON from profile_load (lib/profile.sh) and writes two
# files into <output-dir>/.devcontainer/:
#   - docker-compose.yml   (single `dev` service per ARD-0004 v1 minimal case)
#   - devcontainer.json    (per ARD-0003: dockerComposeFile + service: dev)
#
# Secret-URI env vars are NOT resolved here — cmd_open handles that at start
# time and injects via the devcontainer's remoteEnv. We only emit literal env.

# Where boring's bundled templates live. Defaults to the repo's templates/ dir
# when running from a clone; install.sh can override via env.
BORING_TEMPLATE_DIR="${BORING_TEMPLATE_DIR:-${SCRIPT_DIR:-$PWD}/templates}"

# ----------------------------------------------------------------------------
# Public: compose_generate <profile-json> <output-dir>
# ----------------------------------------------------------------------------
# <profile-json>  is the JSON string emitted by profile_load
# <output-dir>    is the wrapped repo's path; we write into <output-dir>/.devcontainer/
compose_generate() {
  local profile_json="$1"
  local output_dir="$2"
  [[ -z "$profile_json" ]] && die "compose_generate: missing profile JSON"
  [[ -z "$output_dir" ]] && die "compose_generate: missing output dir"
  [[ -d "$output_dir" ]] || die "compose_generate: output dir does not exist: $output_dir"
  require_cmd jq

  local devcontainer_dir="$output_dir/.devcontainer"
  mkdir -p "$devcontainer_dir"

  # Egress: write the resolved allowlist to a file that's bind-mounted into
  # the container. Compose only references the file if egress.allow is set;
  # we still create the dir unconditionally so the bind-mount target exists.
  if egress_enabled "$profile_json"; then
    egress_write_allowlist_file "$profile_json" "$devcontainer_dir"
  fi

  _compose_emit_yaml "$profile_json" > "$devcontainer_dir/docker-compose.yml"
  _compose_emit_devcontainer "$profile_json" > "$devcontainer_dir/devcontainer.json"
}

# ----------------------------------------------------------------------------
# Internal: emit docker-compose.yml
# ----------------------------------------------------------------------------
_compose_emit_yaml() {
  local profile_json="$1"
  local theme dockerfile base_image template_path
  theme="$(jq -r '.theme // ""' <<<"$profile_json")"
  dockerfile="$(jq -r '.stack.dockerfile // ""' <<<"$profile_json")"
  base_image="$(jq -r '.stack.base_image // ""' <<<"$profile_json")"

  # Build/image directive. Theme presets resolve to a template Dockerfile path
  # that boring bundles; explicit dockerfile/base_image override.
  local image_directive
  if [[ -n "$dockerfile" ]]; then
    image_directive="    build:
      context: ..
      dockerfile: $dockerfile"
  elif [[ "$base_image" == "boring/shopify-theme:v1" ]]; then
    template_path="$BORING_TEMPLATE_DIR/shopify"
    local common_path="$BORING_TEMPLATE_DIR/_common"
    [[ -d "$template_path" ]] || die "compose_generate: theme preset template missing: $template_path"
    [[ -d "$common_path" ]]   || die "compose_generate: shared template missing: $common_path"
    # additional_contexts lets the preset Dockerfile COPY --from=common
    # to pull shared assets (Claude defaults, skills, etc.) out of
    # templates/_common/ without duplicating per preset.
    image_directive="    build:
      context: $template_path
      additional_contexts:
        common: $common_path"
  elif [[ -n "$base_image" ]]; then
    image_directive="    image: $base_image"
  else
    die "compose_generate: profile has neither stack.dockerfile nor stack.base_image (and no theme preset matched)"
  fi

  # Volumes: source bind-mount + each profile mount entry, plus the egress
  # allowlist file when egress is enabled (host-writes / container-reads, RO).
  # `..` resolves to the repo root because the compose file lives at
  # <repo>/.devcontainer/docker-compose.yml. Don't use `.` here — it would
  # mount only the .devcontainer/ directory.
  local extra_mounts_json='[]'
  if egress_enabled "$profile_json"; then
    # Relative path is fine because the compose file lives at
    # <repo>/.devcontainer/docker-compose.yml, so ./boring-runtime/... resolves.
    extra_mounts_json='["./boring-runtime/egress.allow:/etc/boring/egress.allow:ro"]'
  fi
  local volumes
  volumes="$(jq -r --argjson extra "$extra_mounts_json" '
    ["..:/workspace:cached"] +
    (.mounts | map(
      if .ro then "\(.host):\(.container):ro" else "\(.host):\(.container)" end
    )) +
    $extra
    | map("      - \"" + . + "\"") | join("\n")
  ' <<<"$profile_json")"

  # Egress enforcement directives (ARD-0011). cap_add + the BORING_EGRESS_MODE
  # env var are only emitted when egress.allow is non-empty.
  local cap_add_block="" egress_env=""
  if egress_enabled "$profile_json"; then
    cap_add_block="    cap_add:
      - NET_ADMIN"
    # Default to enforce; cmd_open's --learn-mode overrides via docker-compose
    # override file or remoteEnv at devcontainer-up time.
    egress_env="BORING_EGRESS_MODE"
  fi

  # Ports: "host:container" pairs.
  local ports
  ports="$(jq -r '
    .forward_ports | map("      - \"\(.):\(.)\"") | join("\n")
  ' <<<"$profile_json")"

  # Environment: literal values only. Secret URIs are deferred to cmd_open's
  # remoteEnv injection step. Egress mode is injected as a literal pulled from
  # the host env at compose-up time (`${BORING_EGRESS_MODE:-enforce}`) so
  # `--learn-mode` flips it without regenerating the compose file.
  local env_block
  env_block="$(jq -r '
    .env | to_entries
    | map(select(.value.kind == "literal"))
    | map("      \(.key): \"\(.value.value)\"")
    | join("\n")
  ' <<<"$profile_json")"

  cat <<EOF
# Generated by boring — do not edit by hand.
# Edit .boring/profile.yaml in this repo and re-run \`boring open\`.

services:
  dev:
$image_directive
    working_dir: /workspace
    command: sleep infinity
    volumes:
$volumes
EOF
  if [[ -n "$cap_add_block" ]]; then
    echo "$cap_add_block"
  fi
  if [[ -n "$ports" ]]; then
    echo "    ports:"
    echo "$ports"
  fi
  if [[ -n "$env_block" || -n "$egress_env" ]]; then
    echo "    environment:"
    [[ -n "$env_block" ]] && echo "$env_block"
    if [[ -n "$egress_env" ]]; then
      # Use compose interpolation so --learn-mode (which sets the host env var
      # before `devcontainer up`) flips the mode without rewriting this file.
      echo "      BORING_EGRESS_MODE: \"\${BORING_EGRESS_MODE:-enforce}\""
    fi
  fi
}

# ----------------------------------------------------------------------------
# Internal: emit devcontainer.json
# ----------------------------------------------------------------------------
_compose_emit_devcontainer() {
  local profile_json="$1"
  # remoteUser:dev tells devcontainer-cli to exec as dev — required because the
  # image no longer sets USER dev (ARD-0011: install-egress runs as root at
  # entrypoint, drops via gosu). Without remoteUser, `devcontainer exec` would
  # default to root.
  jq -n \
    --argjson p "$profile_json" '
    {
      "name": $p.name,
      "dockerComposeFile": "docker-compose.yml",
      "service": "dev",
      "workspaceFolder": "/workspace",
      "remoteUser": "dev",
      "forwardPorts": $p.forward_ports,
      "shutdownAction": "stopCompose"
    }
  '
}
