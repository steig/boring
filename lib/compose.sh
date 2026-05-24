#!/usr/bin/env bash
#
# lib/compose.sh — generate docker-compose.yml + devcontainer.json from a parsed profile.
#
# Consumes the normalized JSON from profile_load (lib/profile.sh) and writes two
# files into <output-dir>/.devcontainer/:
#   - docker-compose.yml   (dev service + ARD-0007 sidecars + top-level volumes)
#   - devcontainer.json    (per ARD-0003: dockerComposeFile + service: dev;
#                           ARD-0007: postCreateCommand for `setup:` lifecycle)
#
# Secret-URI env vars are NOT resolved here — cmd_open handles that at start
# time and injects via the devcontainer's remoteEnv. We only emit literal env.
#
# When `services:` is non-empty (django-node and friends), each entry becomes
# its own compose service alongside `dev`, and `dev.depends_on` is auto-wired
# to wait on each sidecar (condition: service_healthy when the sidecar has a
# healthcheck, else service_started).

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

  _compose_emit_yaml "$profile_json" > "$devcontainer_dir/docker-compose.yml"
  _compose_emit_devcontainer "$profile_json" > "$devcontainer_dir/devcontainer.json"
}

# ----------------------------------------------------------------------------
# Internal: emit docker-compose.yml
# ----------------------------------------------------------------------------
_compose_emit_yaml() {
  local profile_json="$1"
  local preset dockerfile base_image template_path
  preset="$(jq -r '.preset // ""' <<<"$profile_json")"
  dockerfile="$(jq -r '.stack.dockerfile // ""' <<<"$profile_json")"
  base_image="$(jq -r '.stack.base_image // ""' <<<"$profile_json")"

  # Build/image directive. Presets resolve to a template Dockerfile path that
  # boring bundles; explicit dockerfile/base_image override. The base_image
  # values "boring/<preset>:v1" are sentinel values set by lib/profile.sh's
  # normalizer — never real registry images.
  local image_directive preset_subdir=""
  case "$base_image" in
    boring/shopify-theme:v1) preset_subdir="shopify" ;;
    boring/django-node:v1)   preset_subdir="django-node" ;;
  esac

  if [[ -n "$dockerfile" ]]; then
    image_directive="    build:
      context: ..
      dockerfile: $dockerfile"
  elif [[ -n "$preset_subdir" ]]; then
    template_path="$BORING_TEMPLATE_DIR/$preset_subdir"
    local common_path="$BORING_TEMPLATE_DIR/_common"
    [[ -d "$template_path" ]] || die "compose_generate: preset template missing: $template_path"
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
    die "compose_generate: profile has neither stack.dockerfile nor stack.base_image (and no preset matched)"
  fi

  # Volumes: source bind-mount + each profile mount entry.
  # `..` resolves to the repo root because the compose file lives at
  # <repo>/.devcontainer/docker-compose.yml. Don't use `.` here — it would
  # mount only the .devcontainer/ directory.
  local volumes
  volumes="$(jq -r '
    ["..:/workspace:cached"] +
    (.mounts | map(
      if .ro then "\(.host):\(.container):ro" else "\(.host):\(.container)" end
    ))
    | map("      - \"" + . + "\"") | join("\n")
  ' <<<"$profile_json")"

  # Ports: "host:container" pairs.
  local ports
  ports="$(jq -r '
    .forward_ports | map("      - \"\(.):\(.)\"") | join("\n")
  ' <<<"$profile_json")"

  # Environment: literal values only. Secret URIs are deferred to cmd_open's
  # remoteEnv injection step.
  local env_block
  env_block="$(jq -r '
    .env | to_entries
    | map(select(.value.kind == "literal"))
    | map("      \(.key): \"\(.value.value)\"")
    | join("\n")
  ' <<<"$profile_json")"

  # depends_on for the dev service. Auto-wires the dev service to wait for
  # every declared sidecar — service_healthy if the sidecar has a healthcheck,
  # service_started otherwise. Long-form (per-service condition) so we can
  # express the healthcheck distinction without copying compose docs.
  local depends_block
  depends_block="$(jq -r '
    .services
    | map("      \(.name):\n        condition: " +
          (if .healthcheck == null then "service_started" else "service_healthy" end))
    | join("\n")
  ' <<<"$profile_json")"

  # Sidecar service blocks. Each emits image, env, volumes (if any), and
  # healthcheck (if any). depends_on between sidecars is supported through
  # the profile-declared depends_on list.
  local sidecars_block
  sidecars_block="$(jq -r '
    .services
    | map(
        "  \(.name):\n" +
        "    image: \(.image)\n" +
        (if (.env | length) > 0 then
           "    environment:\n" +
           (.env | to_entries | map("      \(.key): \"\(.value)\"") | join("\n")) + "\n"
         else "" end) +
        (if (.volumes | length) > 0 then
           "    volumes:\n" +
           (.volumes | map("      - \"\(.)\"") | join("\n")) + "\n"
         else "" end) +
        (if .healthcheck != null then
           "    healthcheck:\n" +
           (.healthcheck | to_entries | map(
              "      \(.key): " +
              (if (.value | type) == "array"
                then "[" + (.value | map("\"\(.)\"") | join(", ")) + "]"
                else "\(.value)" end)
            ) | join("\n")) + "\n"
         else "" end) +
        (if (.depends_on | length) > 0 then
           "    depends_on:\n" +
           (.depends_on | map("      - \(.)") | join("\n")) + "\n"
         else "" end)
      )
    | join("")
  ' <<<"$profile_json")"

  # Top-level named volumes. Compose requires these to be declared at the file
  # root when referenced by service.volumes entries of the form "name:/path".
  local top_volumes_block
  top_volumes_block="$(jq -r '
    if (.volumes | length) == 0 then ""
    else "\nvolumes:\n" + (.volumes | map("  \(.): {}") | join("\n")) + "\n"
    end
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
  if [[ -n "$ports" ]]; then
    echo "    ports:"
    echo "$ports"
  fi
  if [[ -n "$env_block" ]]; then
    echo "    environment:"
    echo "$env_block"
  fi
  if [[ -n "$depends_block" ]]; then
    echo "    depends_on:"
    echo "$depends_block"
  fi
  if [[ -n "$sidecars_block" ]]; then
    # Leading newline so the first sidecar is visually separated from the dev
    # block — non-functional but easier to scan.
    echo
    printf '%s' "$sidecars_block"
  fi
  if [[ -n "$top_volumes_block" ]]; then
    printf '%s' "$top_volumes_block"
  fi
}

# ----------------------------------------------------------------------------
# Internal: emit devcontainer.json
# ----------------------------------------------------------------------------
# `setup:` (ARD-0007 §5) → `postCreateCommand`. The chain (set -e + marker
# dance + setup commands) is built by profile_setup_command in lib/profile.sh
# — single source so the boring-side re-run path doesn't drift from the
# devcontainer-side hook.
_compose_emit_devcontainer() {
  local profile_json="$1"
  local setup_cmd
  setup_cmd="$(profile_setup_command "$profile_json")"

  jq -n \
    --argjson p "$profile_json" \
    --arg setup_cmd "$setup_cmd" '
    {
      "name": $p.name,
      "dockerComposeFile": "docker-compose.yml",
      "service": "dev",
      "workspaceFolder": "/workspace",
      "forwardPorts": $p.forward_ports,
      "shutdownAction": "stopCompose"
    }
    + (if $setup_cmd == "" then {} else {"postCreateCommand": $setup_cmd} end)
  '
}
