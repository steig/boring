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
# Public: compose_generate <profile-json> <output-dir> [--project-name <name>]
# ----------------------------------------------------------------------------
# <profile-json>     is the JSON string emitted by profile_load
# <output-dir>       is the wrapped repo's path; we write into <output-dir>/.devcontainer/
# --project-name     optional top-level `name:` field for the docker-compose.yml,
#                    used by `boring run` (ARD-0013) to scope a one-shot compose
#                    stack to a unique project name so it doesn't collide with
#                    an interactive `boring open` of the same profile.
compose_generate() {
  local profile_json="$1"
  local output_dir="$2"
  shift 2 || true
  local project_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-name) project_name="${2:?--project-name requires a value}"; shift 2 ;;
      *) die "compose_generate: unknown argument: $1" ;;
    esac
  done

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
    # ARD-0015: egress-logger sidecar shares ./boring-runtime/egress-log with
    # the dev container (RW for sidecar, RO for dev). Pre-create the dir so
    # docker doesn't auto-create it as root and so the directory exists at
    # `docker compose up` time before either container mounts it.
    mkdir -p "$devcontainer_dir/boring-runtime/egress-log"
  fi

  _compose_emit_yaml "$profile_json" "$project_name" > "$devcontainer_dir/docker-compose.yml"
  _compose_emit_devcontainer "$profile_json" > "$devcontainer_dir/devcontainer.json"
}

# ----------------------------------------------------------------------------
# Public: _compose_emit_guardrails_runtime <profile-json> <output-dir>
# ----------------------------------------------------------------------------
# ARD-0009: emit the three guardrails artifacts into
#   <output-dir>/.devcontainer/boring-runtime/
# Bind-mounted RO into the container; the agent inside cannot rewrite them.
#
#   pre-push                          fires when guardrails.forbid_branches set
#   pre-commit                        trust-anchor (ARD-0006); always emitted
#   bin/<cmd>                         one per unique binary in forbid_commands
#   claude/settings.json              jq-deep-merge of image baseline + allow
#
# Always runs (never short-circuits) because the bind-mount in
# docker-compose.yml references the runtime dir; it must exist for compose to
# start the container. A profile with no guardrails fields gets a no-op
# pre-push, an empty bin/, and a baseline-only settings.json — all harmless.
_compose_emit_guardrails_runtime() {
  local profile_json="$1"
  local output_dir="$2"
  [[ -z "$profile_json" ]] && die "_compose_emit_guardrails_runtime: missing profile JSON"
  [[ -z "$output_dir" ]] && die "_compose_emit_guardrails_runtime: missing output dir"
  [[ -d "$output_dir" ]] || die "_compose_emit_guardrails_runtime: output dir does not exist: $output_dir"
  require_cmd jq

  local runtime_dir="$output_dir/.devcontainer/boring-runtime"
  mkdir -p "$runtime_dir/bin" "$runtime_dir/claude"

  _guardrails_emit_pre_push "$profile_json" > "$runtime_dir/pre-push"
  chmod 0755 "$runtime_dir/pre-push"

  _guardrails_emit_pre_commit > "$runtime_dir/pre-commit"
  chmod 0755 "$runtime_dir/pre-commit"

  _guardrails_emit_wrappers "$profile_json" "$runtime_dir/bin"

  _guardrails_emit_claude_settings "$profile_json" > "$runtime_dir/claude/settings.json"

  # ARD-0010 audit-emit shim + per-kind symlinks. Same host-writes,
  # container-reads-RO pattern as the rest of boring-runtime/. Was originally
  # image-baked into /usr/local/boring/bin/ but that path was in the
  # container's writable layer (sudo + dev user → modifiable). Moved here so
  # the RO bind-mount makes it structurally immutable from inside.
  _audit_emit_install "$runtime_dir/bin"
}

# Copy the audit-emit shim from the shared common template into the runtime
# bin/ dir, and create the per-kind symlinks Claude Code's hooks invoke.
# The script itself lives at templates/_common/boring-bin/audit-emit; we
# don't generate it inline because it's substantive (~80 lines) and shared.
_audit_emit_install() {
  local bin_dir="$1"
  local src="$BORING_TEMPLATE_DIR/_common/boring-bin/audit-emit"
  [[ -f "$src" ]] || die "_audit_emit_install: source missing: $src"

  install -m 0755 "$src" "$bin_dir/audit-emit"
  # ln -sf is idempotent; the runtime dir may already exist from a prior open.
  for kind in prompt_issued tool_used prompt_completed; do
    ln -sf audit-emit "$bin_dir/audit-emit-$kind"
  done
}

# Render the pre-push hook. git invokes it with `<remote-name> <remote-url>`
# as argv and the list of refs being pushed on stdin, one per line:
#   <local-ref> <local-sha> <remote-ref> <remote-sha>
# We refuse if any <remote-ref> matches a forbidden branch (full ref form
# `refs/heads/<name>` or bare `<name>`).
_guardrails_emit_pre_push() {
  local profile_json="$1"
  local forbidden
  forbidden="$(jq -r '.guardrails.forbid_branches // [] | .[]' <<<"$profile_json")"

  cat <<'HOOK_HEAD'
#!/usr/bin/env bash
# Generated by boring — do not edit. (ARD-0009)
# Reads git's pre-push contract on stdin and refuses pushes to forbidden refs.
set -eu

HOOK_HEAD

  if [[ -z "$forbidden" ]]; then
    cat <<'HOOK_EMPTY'
exit 0
HOOK_EMPTY
    return 0
  fi

  echo "forbidden_branches=("
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    # Single-quote each entry; double any embedded single-quotes per POSIX.
    printf '  %q\n' "$branch"
  done <<<"$forbidden"
  echo ")"

  cat <<'HOOK_BODY'

while read -r _local_ref _local_sha remote_ref _remote_sha; do
  [[ -z "$remote_ref" ]] && continue
  remote_name="${remote_ref#refs/heads/}"
  for fb in "${forbidden_branches[@]}"; do
    fb_name="${fb#refs/heads/}"
    if [[ "$remote_name" == "$fb_name" || "$remote_ref" == "$fb" ]]; then
      echo "[boring] refusing to push to forbidden branch: $remote_ref" >&2
      echo "         guardrails.forbid_branches in .boring/profile.yaml lists this branch (ARD-0009)." >&2
      echo "         Edit the profile on the HOST to change this." >&2
      exit 1
    fi
  done
done
exit 0
HOOK_BODY
}

# Render the trust-anchor pre-commit (ARD-0006) into the runtime dir. We
# duplicate the image-baked content here because Dockerfile changes set
# core.hooksPath to the runtime dir; keeping the rule emitted from both
# places means a missing bind-mount or a missing image bake each fail safe
# on the other.
_guardrails_emit_pre_commit() {
  cat <<'HOOK'
#!/bin/sh
# Generated by boring — do not edit. (ARD-0006 trust anchor)
set -e
if git diff --cached --name-only | grep -q "^\.boring/"; then
  echo "[boring] refusing to commit changes to .boring/ from inside the container." >&2
  echo "         .boring/profile.yaml is the trust anchor (ARD-0006). Edit it on the HOST." >&2
  exit 1
fi
if git diff --cached --name-only | grep -q "^\.devcontainer/boring-runtime/"; then
  echo "[boring] refusing to commit changes to .devcontainer/boring-runtime/ from inside the container." >&2
  echo "         These files are generated by boring (ARD-0009). Edit .boring/profile.yaml on the HOST." >&2
  exit 1
fi
HOOK
}

# For each forbid_commands entry, group by first token (binary name) and emit
# one wrapper that prefix-matches the joined argv string against every pattern
# for that binary. Wrappers live earlier on PATH than the real binary (the
# container's profile.d snippet handles PATH); on no-match, the wrapper strips
# its own dir from PATH and execs the real binary.
_guardrails_emit_wrappers() {
  local profile_json="$1"
  local bin_dir="$2"

  # Group patterns by binary name (first whitespace-separated token).
  # Output: one line per binary, JSON array of its patterns.
  local groups
  groups="$(jq -r '
    .guardrails.forbid_commands // []
    | map(select(type == "string" and . != ""))
    | group_by(. | split(" ") | .[0])
    | map({bin: (.[0] | split(" ") | .[0]), patterns: .})
    | .[]
    | "\(.bin)\t\(.patterns | @json)"
  ' <<<"$profile_json")"

  [[ -z "$groups" ]] && return 0

  while IFS=$'\t' read -r bin patterns_json; do
    [[ -z "$bin" ]] && continue
    # Reject binary names that aren't a simple slug-ish token. Anything weirder
    # is a profile authoring bug; refuse to emit a wrapper rather than create a
    # file with surprising semantics.
    if [[ ! "$bin" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      die "_guardrails_emit_wrappers: refuse to emit wrapper for unsafe binary name: $bin"
    fi
    _guardrails_render_wrapper "$bin" "$patterns_json" > "$bin_dir/$bin"
    chmod 0755 "$bin_dir/$bin"
  done <<<"$groups"
}

# Render one wrapper. Patterns are emitted as a quoted bash array; argv
# matching is a literal prefix match against the space-joined argv string.
_guardrails_render_wrapper() {
  local bin="$1" patterns_json="$2"

  cat <<HEAD
#!/usr/bin/env bash
# Generated by boring — do not edit. (ARD-0009)
# Wrapper for: $bin
set -eu

HEAD

  echo "forbidden_patterns=("
  # Decode JSON array into one printf %q'd entry per line. jq -r emits one
  # raw string per element; %q then bash-quotes each safely.
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    printf '  %q\n' "$pat"
  done < <(jq -r '.[]' <<<"$patterns_json")
  echo ")"

  cat <<BODY

argv_str="$bin \$*"
for pat in "\${forbidden_patterns[@]}"; do
  case "\$argv_str " in
    "\$pat "*)
      echo "[boring] refusing forbidden command: \$argv_str" >&2
      echo "         matched guardrails.forbid_commands entry: \$pat" >&2
      echo "         (ARD-0009; edit .boring/profile.yaml on the HOST to change this)" >&2
      exit 1
      ;;
  esac
done

# Strip our own dir from PATH and exec the real binary.
self_dir="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
clean_path="\$(printf %s "\$PATH" | awk -v d="\$self_dir" 'BEGIN{RS=":"; ORS=":"} \$0 != d' | sed 's/:\$//')"
real="\$(PATH="\$clean_path" command -v "$bin" || true)"
if [[ -z "\$real" || "\$real" == "\${BASH_SOURCE[0]}" ]]; then
  echo "[boring] wrapper for '$bin' could not find the real binary on PATH after stripping \$self_dir" >&2
  exit 127
fi
exec "\$real" "\$@"
BODY
}

# Deep-merge the image-baked baseline (templates/_common/claude/settings.json,
# which is the same file COPYd into the image at /home/dev/.claude/settings.json)
# with a profile-derived snippet built from guardrails.allowed_claude_tools.
# `jq -s '.[0] * .[1]'` is deep-merge: array-valued leaves are REPLACED, not
# concatenated. Our snippet only sets permissions.allow, so the baseline's
# permissions.deny survives unchanged.
_guardrails_emit_claude_settings() {
  local profile_json="$1"
  local baseline="$BORING_TEMPLATE_DIR/_common/claude/settings.json"
  [[ -f "$baseline" ]] || die "_guardrails_emit_claude_settings: baseline missing: $baseline"

  jq -n --slurpfile base "$baseline" --argjson p "$profile_json" '
    ($p.guardrails.allowed_claude_tools // []) as $allow
    | (if ($allow | length) == 0 then {}
       else {permissions: {allow: $allow}}
       end) as $overlay
    | $base[0] * $overlay
  '
}

# ----------------------------------------------------------------------------
# Internal: emit docker-compose.yml
# ----------------------------------------------------------------------------
_compose_emit_yaml() {
  local profile_json="$1"
  local project_name="${2:-}"
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
    boring/python:v1)        preset_subdir="python" ;;
    boring/node:v1)          preset_subdir="node" ;;
    boring/node-postgres:v1) preset_subdir="node-postgres" ;;
  esac

  # ARD-0014: preset_version entries become docker build ARGs. Convention:
  # the map key is uppercased and suffixed with _VERSION (python -> PYTHON_VERSION,
  # node -> NODE_VERSION, ruby -> RUBY_VERSION). The Dockerfile's ARG declaration
  # is the contract — an unknown key just becomes an unused build-arg (Docker
  # warns but doesn't fail). Emitted only when preset_version is non-empty AND
  # a preset build context applies (skipped for stack.dockerfile / stack.base_image).
  local build_args_block=""
  if [[ -n "$preset_subdir" || -n "$dockerfile" ]]; then
    build_args_block="$(jq -r '
      .preset_version // {}
      | to_entries
      | map("        \(.key | ascii_upcase)_VERSION: \"\(.value)\"")
      | join("\n")
    ' <<<"$profile_json")"
  fi

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

  # Append args: block under build: if preset_version produced any entries.
  if [[ -n "$build_args_block" ]]; then
    image_directive="${image_directive}
      args:
${build_args_block}"
  fi

  # Audit FIFO bind-mount (ARD-0010): the per-profile FIFO on the host is
  # mounted into the container as the in-container write target. The container
  # only ever has the writer side of this pipe — no other file under the audit
  # tree is mounted, so an in-container agent cannot rewrite past events.
  local profile_name audit_fifo_host
  profile_name="$(jq -r '.name' <<<"$profile_json")"
  audit_fifo_host="$DATA_DIR/audit/$profile_name/events.fifo"

  # Egress allowlist file (ARD-0011): host-writes/container-reads RO mount,
  # added only when egress is enabled. The file is generated by egress_write_allowlist_file
  # earlier in compose_generate.
  #
  # ARD-0015: when egress is enabled we also share the egress-log directory
  # between the dev container (RO mount) and the egress-logger sidecar (RW).
  # Bind-mount (not docker-named-volume) so boring on the host can read
  # ulogd.json directly at session shutdown without `docker cp`. RO from dev's
  # side keeps anything inside the dev container — agent or otherwise — from
  # editing the JSON ulogd2 wrote before boring parses it.
  local extra_mounts_json='[]'
  if egress_enabled "$profile_json"; then
    extra_mounts_json='["./boring-runtime/egress.allow:/etc/boring/egress.allow:ro","./boring-runtime/egress-log:/var/log/boring/egress:ro"]'
  fi

  # Volumes: source bind-mount + ARD-0009 guardrails-runtime RO remount +
  # ARD-0010 audit FIFO + ARD-0011 egress allowlist (when enabled) +
  # ARD-0028 AGENTS.md RO bind into OpenCode's config dir +
  # each profile mount entry.
  # `..` resolves to the repo root because the compose file lives at
  # <repo>/.devcontainer/docker-compose.yml. Don't use `.` here — it would
  # mount only the .devcontainer/ directory.
  # The guardrails-runtime path is already inside the workspace bind-mount;
  # the more specific second entry re-mounts it read-only (Docker honors the
  # narrower mount), which is what makes the host-writes-container-reads-RO
  # trust-anchor contract of ARD-0009 hold.
  # Per ARD-0028 the codegen'd AGENTS.md lives at <repo>/.boring/codegen/AGENTS.md
  # and is re-bound at /home/dev/.config/opencode/AGENTS.md (RO) so OpenCode
  # discovers it via its native convention. The matching CLAUDE.md (ARD-0017) is
  # re-bound RO at /home/dev/.claude/boring-profile.md and pulled in by the
  # image-baked /home/dev/.claude/CLAUDE.md via an `@boring-profile.md` import —
  # the Claude-side equivalent of the OpenCode AGENTS.md path. Both codegen docs
  # are written host-side before compose up, so the bind sources always exist.
  local volumes
  volumes="$(jq -r --arg fifo "$audit_fifo_host" --argjson extra "$extra_mounts_json" '
    ["..:/workspace:cached",
     "../.devcontainer/boring-runtime:/workspace/.devcontainer/boring-runtime:ro",
     "../.boring/codegen/AGENTS.md:/home/dev/.config/opencode/AGENTS.md:ro",
     "../.boring/codegen/CLAUDE.md:/home/dev/.claude/boring-profile.md:ro",
     ($fifo + ":/var/log/boring/events.fifo")] +
    (.mounts | map(
      if .ro then "\(.host):\(.container):ro" else "\(.host):\(.container)" end
    )) +
    $extra
    | map("      - \"" + . + "\"") | join("\n")
  ' <<<"$profile_json")"

  # Egress enforcement directives (ARD-0011). cap_add + the BORING_EGRESS_MODE
  # env var are only emitted when egress.allow is non-empty.
  local cap_add_block="" egress_env="" egress_sidecars=""
  if egress_enabled "$profile_json"; then
    cap_add_block="    cap_add:
      - NET_ADMIN"
    # Default to enforce; cmd_open's --learn-mode overrides via docker-compose
    # override file or remoteEnv at devcontainer-up time.
    egress_env="BORING_EGRESS_MODE"
    # ARD-0036 cross_sandbox: pass the declared sidecar service names to
    # install-egress so it can carve them out of the docker-subnet/RFC1918 drops
    # (otherwise dev → postgres/redis breaks). Space-separated .services[].name.
    egress_sidecars="$(jq -r '.services | map(.name) | join(" ")' <<<"$profile_json")"
  fi

  # ARD-0015 egress-logger sidecar — emitted whenever egress is enabled (not
  # gated on BORING_EGRESS_MODE, which the user sets at run time, not at
  # `boring open` time). In enforce mode iptables uses REJECT and the sidecar
  # sees zero NFLOG packets, sitting idle; in learn mode it captures and
  # writes ulogd.json to the shared bind-mount. Single compose file, one
  # generated path, mode flips without regen.
  #
  # NOTE on depends_on direction: ARD-0015 §"Sidecar lifecycle" originally
  # called for `dev depends_on egress-logger` so ulogd2 binds the netlink
  # socket before iptables NFLOG rules fire. That cannot work with
  # `network_mode: "service:dev"` — compose auto-adds the reverse dependency
  # (egress-logger needs dev's netns to attach), and the two together form a
  # cycle. We accept compose's implicit ordering (dev starts first; sidecar
  # attaches its netns next, within ~1s). install-egress installs NFLOG
  # rules then execs `sleep infinity` — no user traffic until the user
  # invokes commands interactively, which is well after ulogd2 is bound.
  # The race window only matters if first-traffic happens in <1s of dev
  # boot, which the post-installEgress workload doesn't do.
  local egress_logger_sidecar_block=""
  if egress_enabled "$profile_json"; then
    local egress_logger_ctx="$BORING_TEMPLATE_DIR/_common/egress-logger"
    [[ -d "$egress_logger_ctx" ]] || die "compose_generate: egress-logger template missing: $egress_logger_ctx"
    egress_logger_sidecar_block="  egress-logger:
    build:
      context: $egress_logger_ctx
    network_mode: \"service:dev\"
    cap_add:
      - NET_ADMIN
    volumes:
      - \"./boring-runtime/egress-log:/var/log/boring/egress\"
    restart: \"no\"
"
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
  # JSON-encode each value (tojson) so embedded quotes/backslashes/newlines
  # produce a valid YAML scalar (YAML is a JSON superset), and double every `$`
  # so Docker Compose's variable interpolation can't mangle values that legibly
  # contain `$` (passwords, DSNs). Compose un-escapes `$$`→`$` at parse time.
  # tostring guards non-string literals (e.g. `FOO: 5`) before gsub.
  env_block="$(jq -r '
    .env | to_entries
    | map(select(.value.kind == "literal"))
    | map("      \(.key): \((.value.value | tostring | gsub("\\$"; "$$")) | tojson)")
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
           (.env | to_entries | map("      \(.key): \((.value | tostring | gsub("\\$"; "$$")) | tojson)") | join("\n")) + "\n"
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

EOF
  if [[ -n "$project_name" ]]; then
    # ARD-0013: explicit top-level `name:` lets `boring run` scope a one-shot
    # compose stack so it doesn't collide with an interactive `boring open` of
    # the same profile. Docker Compose honors this field (compose-spec).
    echo "name: $project_name"
    echo
  fi
  cat <<EOF
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
      # ARD-0036: literal sidecar names (empty string when no sidecars declared,
      # in which case install-egress just drops the whole subnet).
      echo "      BORING_EGRESS_SIDECARS: \"${egress_sidecars}\""
    fi
  fi
  if [[ -n "$depends_block" ]]; then
    echo "    depends_on:"
    echo "$depends_block"
  fi
  if [[ -n "$sidecars_block" || -n "$egress_logger_sidecar_block" ]]; then
    # Leading newline so the first sidecar is visually separated from the dev
    # block — non-functional but easier to scan.
    echo
    # `$(...)` strips the trailing newline from sidecars_block, so re-add one
    # or the egress-logger block gets glued onto the last sidecar line (e.g.
    # `retries: 10  egress-logger:`) → invalid compose YAML.
    [[ -n "$sidecars_block" ]] && printf '%s\n' "$sidecars_block"
    [[ -n "$egress_logger_sidecar_block" ]] && printf '%s' "$egress_logger_sidecar_block"
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

  # remoteUser:dev tells devcontainer-cli to exec as dev — required because the
  # image no longer sets USER dev (ARD-0011: install-egress runs as root at
  # entrypoint, drops via gosu). Without remoteUser, `devcontainer exec` would
  # default to root.
  jq -n \
    --argjson p "$profile_json" \
    --arg setup_cmd "$setup_cmd" '
    {
      "name": $p.name,
      "dockerComposeFile": "docker-compose.yml",
      "service": "dev",
      "workspaceFolder": "/workspace",
      "remoteUser": "dev",
      "forwardPorts": $p.forward_ports,
      "shutdownAction": "stopCompose",
      "remoteUser": "dev"
    }
    + (if $setup_cmd == "" then {} else {"postCreateCommand": $setup_cmd} end)
    # ARD-0018: profile-declared VS Code extensions + workspace settings. The VS
    # Code extensions array takes bare publisher.id, so strip any @version pin
    # (the pin is recorded in the profile; autoUpdate:false keeps the installed
    # version from drifting). extension_settings merges into settings.
    + (
        ($p.extensions // []) as $exts
      | ($p.extension_settings // {}) as $extset
      | if (($exts | length) > 0) or (($extset | length) > 0)
        then {
          "customizations": { "vscode": (
            (if ($exts | length) > 0 then { "extensions": ($exts | map(split("@")[0])) } else {} end)
            + { "settings": ($extset + (if ($exts | length) > 0 then {"extensions.autoUpdate": false} else {} end)) }
          ) }
        }
        else {} end
      )
  '
}
