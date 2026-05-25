#!/usr/bin/env bash
#
# lib/guardrails.sh — per-harness translation tables + the codegen artifacts
# that those tables produce (OpenCode permissions JSON, AGENTS.md/CLAUDE.md
# sibling files, resolved path allowlist).
#
# Companion to lib/compose.sh's _compose_emit_guardrails_runtime, which still
# owns the original three ARD-0009 artifacts (pre-push hook, command wrappers,
# Claude settings.json). This file extends the codegen surface with the
# harness-agnostic pieces from ARD-0026 + ARD-0028 + ARD-0022.
#
# Per ARD-0026 §2, harness-knowledge is colocated here. Translation tables map
# from canonical tool names (boring's own vocabulary) to per-harness native
# names. Two harnesses today (Claude, OpenCode); a third = a third table.

# ----------------------------------------------------------------------------
# Translation tables (case-statement form; bash 3.2 lacks declare -A)
# ----------------------------------------------------------------------------
# Canonical tool vocabulary: edit, run, read, web_fetch, web_search. Unknown
# canonical names → empty (drop signal). OpenCode names are placeholders
# pending ARD-0020 subscription-verification + OpenCode v1.x API verification.

_guardrails_claude_tool() {
  case "$1" in
    edit)       printf 'Edit\n' ;;
    run)        printf 'Bash\n' ;;
    read)       printf 'Read\n' ;;
    web_fetch)  printf 'WebFetch\n' ;;
    web_search) printf 'WebSearch\n' ;;
    *)          : ;;
  esac
}

# TODO(ARD-0020/ARD-0026 §2): OpenCode names below are placeholders.
_guardrails_opencode_tool() {
  case "$1" in
    edit)       printf 'file_edit\n' ;;
    run)        printf 'shell_exec\n' ;;
    read)       printf 'file_read\n' ;;
    web_fetch)  printf 'http_get\n' ;;
    web_search) printf 'web_search\n' ;;
    *)          : ;;
  esac
}

# Where boring's bundled templates live. Mirrors lib/compose.sh so this module
# can be sourced standalone (tests do this).
BORING_TEMPLATE_DIR="${BORING_TEMPLATE_DIR:-${SCRIPT_DIR:-$PWD}/templates}"

# ----------------------------------------------------------------------------
# guardrails_translate_tools <map-name> <canonical-tool>...
# ----------------------------------------------------------------------------
# Translate one or more canonical tool names through the named map. Emits one
# translated name per line on stdout; unsupported tools are dropped silently
# (callers that want the warning emit it themselves to keep this function pure).
# map-name must be "claude" or "opencode".
guardrails_translate_tools() {
  local map="$1"; shift
  local tool native
  for tool in "$@"; do
    case "$map" in
      claude)   native="$(_guardrails_claude_tool "$tool")"   ;;
      opencode) native="$(_guardrails_opencode_tool "$tool")" ;;
      *) die "guardrails_translate_tools: unknown map: $map (expected claude|opencode)" ;;
    esac
    [[ -z "$native" ]] && continue
    printf '%s\n' "$native"
  done
}

# ----------------------------------------------------------------------------
# guardrails_resolve_paths <profile-json> <preset>
# ----------------------------------------------------------------------------
# Per ARD-0026 §3 + ARD-0022 §5.1: resolve the effective path allowlist as
# (preset default + profile.allowed_paths) − profile.disallowed_paths.
# Reads the preset default from templates/<preset>/allowed-paths.yaml (the
# file is optional; missing → empty default). Output: JSON array on stdout.
guardrails_resolve_paths() {
  local profile_json="$1" preset="$2"
  require_cmd jq

  local defaults_path defaults_json="[]"
  if [[ -n "$preset" ]]; then
    defaults_path="$BORING_TEMPLATE_DIR/$preset/allowed-paths.yaml"
    if [[ -f "$defaults_path" ]]; then
      require_cmd yq
      defaults_json="$(yq -o=json '.allowed_paths // []' "$defaults_path")"
    fi
  fi

  jq -n --argjson p "$profile_json" --argjson d "$defaults_json" '
    ($d + ($p.allowed_paths // [])) as $combined
    | ($p.disallowed_paths // []) as $deny
    | $combined - $deny
    | unique
  '
}

# ----------------------------------------------------------------------------
# guardrails_emit_opencode_permissions <profile-json> <out-path>
# ----------------------------------------------------------------------------
# Per ARD-0026 §4 (artifact #5): write the resolved tool + path allowlists
# into an OpenCode-shaped permission config JSON. OpenCode's actual config
# schema is verified at ARD-0020 implementation time.
guardrails_emit_opencode_permissions() {
  local profile_json="$1" out_path="$2"
  [[ -z "$profile_json" ]] && die "guardrails_emit_opencode_permissions: missing profile JSON"
  [[ -z "$out_path" ]] && die "guardrails_emit_opencode_permissions: missing out path"
  require_cmd jq

  local preset
  preset="$(jq -r '.preset // ""' <<<"$profile_json")"

  # Translate canonical tools to OpenCode-native names; one per line.
  local canonical_tools=()
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    canonical_tools+=("$t")
  done < <(jq -r '.guardrails.allowed_tools // [] | .[]' <<<"$profile_json")

  local opencode_tools=()
  if [[ ${#canonical_tools[@]} -gt 0 ]]; then
    while IFS= read -r t; do
      [[ -z "$t" ]] && continue
      opencode_tools+=("$t")
    done < <(guardrails_translate_tools opencode "${canonical_tools[@]+"${canonical_tools[@]}"}")
  fi

  # Build the tools array as a JSON value. Empty array if nothing translated.
  local tools_json="[]"
  if [[ ${#opencode_tools[@]} -gt 0 ]]; then
    tools_json="$(printf '%s\n' "${opencode_tools[@]+"${opencode_tools[@]}"}" | jq -R . | jq -s .)"
  fi

  local paths_json
  paths_json="$(guardrails_resolve_paths "$profile_json" "$preset")"

  jq -n \
    --argjson tools "$tools_json" \
    --argjson paths "$paths_json" '
    {
      version: "1",
      tools:   { allow: $tools },
      paths:   { allow: $paths }
    }
  ' > "$out_path"
}

# ----------------------------------------------------------------------------
# guardrails_emit_agent_doc <profile-json> <harness> <out-path>
# ----------------------------------------------------------------------------
# Per ARD-0017 + ARD-0028: render templates/_shared/agent/workflow.md with
# per-harness substitutions. harness = "claude" or "opencode"; the substitution
# table chooses tool-name vocabulary and the file-self-reference name.
guardrails_emit_agent_doc() {
  local profile_json="$1" harness="$2" out_path="$3"
  [[ -z "$profile_json" ]] && die "guardrails_emit_agent_doc: missing profile JSON"
  [[ -z "$harness" ]] && die "guardrails_emit_agent_doc: missing harness (claude|opencode)"
  [[ -z "$out_path" ]] && die "guardrails_emit_agent_doc: missing out path"
  require_cmd jq

  local src="$BORING_TEMPLATE_DIR/_shared/agent/workflow.md"
  [[ -f "$src" ]] || die "guardrails_emit_agent_doc: source missing: $src"

  # Choose substitution values per harness. The filename token lets a phrase
  # in the universal block ("if this file is named X") render correctly per
  # harness without forking the source.
  local tool_edit tool_run tool_read filename
  case "$harness" in
    claude)
      tool_edit="$(_guardrails_claude_tool edit)"
      tool_run="$(_guardrails_claude_tool run)"
      tool_read="$(_guardrails_claude_tool read)"
      filename="CLAUDE.md"
      ;;
    opencode)
      tool_edit="$(_guardrails_opencode_tool edit)"
      tool_run="$(_guardrails_opencode_tool run)"
      tool_read="$(_guardrails_opencode_tool read)"
      filename="AGENTS.md"
      ;;
    *)
      die "guardrails_emit_agent_doc: unknown harness: $harness (expected claude|opencode)"
      ;;
  esac

  # Per-profile snippet: bullet list of forbid_branches + forbid_commands from
  # the resolved profile (ARD-0017 §2). Empty lists render as "(none)" so the
  # agent gets a clear signal rather than a silent gap. Snippet is multi-line
  # so we write it to a temp file and splice with awk's getline rather than
  # passing it via -v (awk -v can't carry embedded newlines portably).
  local snippet_file="$out_path.snippet.tmp"
  _guardrails_render_profile_snippet "$profile_json" > "$snippet_file"

  awk -v edit="$tool_edit" -v run="$tool_run" -v read="$tool_read" \
      -v fname="$filename" -v snippet_file="$snippet_file" '
    {
      gsub(/\{\{TOOL_EDIT\}\}/, edit)
      gsub(/\{\{TOOL_RUN\}\}/, run)
      gsub(/\{\{TOOL_READ\}\}/, read)
      gsub(/\{\{HARNESS_FILENAME\}\}/, fname)
    }
    /\{\{PROFILE_SNIPPET\}\}/ {
      while ((getline line < snippet_file) > 0) print line
      close(snippet_file)
      next
    }
    { print }
  ' "$src" > "$out_path"
  rm -f "$snippet_file"
}

# Render the per-profile guardrails snippet (markdown bullets). Used by the
# agent doc template's {{PROFILE_SNIPPET}} substitution. Per ARD-0017 §2:
# forbid_branches + forbid_commands as bullets; "(none)" when empty so the
# agent reads "no profile-specific guardrails apply here" explicitly.
_guardrails_render_profile_snippet() {
  local profile_json="$1"
  local branches commands

  branches="$(jq -r '
    .guardrails.forbid_branches // []
    | if length == 0 then "- (none)" else map("- " + .) | join("\n") end
  ' <<<"$profile_json")"

  commands="$(jq -r '
    .guardrails.forbid_commands // []
    | if length == 0 then "- (none)" else map("- `" + . + "`") | join("\n") end
  ' <<<"$profile_json")"

  printf '### Forbidden branches\n%s\n\n### Forbidden commands\n%s' \
    "$branches" "$commands"
}

# ----------------------------------------------------------------------------
# guardrails_emit_codegen_dir <profile-json> <repo-path>
# ----------------------------------------------------------------------------
# Per ARD-0028 + ARD-0026: write the harness-agnostic codegen artifacts into
# <repo>/.boring/codegen/. The CLAUDE.md/AGENTS.md pair lives here (bind-mount
# destinations differ per harness; see lib/compose.sh). The OpenCode permission
# JSON also goes here; lib/compose.sh's existing _compose_emit_guardrails_runtime
# stays untouched (it owns the original ARD-0009 three).
guardrails_emit_codegen_dir() {
  local profile_json="$1" repo_path="$2"
  [[ -z "$profile_json" ]] && die "guardrails_emit_codegen_dir: missing profile JSON"
  [[ -z "$repo_path" ]] && die "guardrails_emit_codegen_dir: missing repo path"
  [[ -d "$repo_path" ]] || die "guardrails_emit_codegen_dir: repo path not a directory: $repo_path"

  local codegen_dir="$repo_path/.boring/codegen"
  mkdir -p "$codegen_dir"

  guardrails_emit_agent_doc "$profile_json" claude   "$codegen_dir/CLAUDE.md"
  guardrails_emit_agent_doc "$profile_json" opencode "$codegen_dir/AGENTS.md"
  guardrails_emit_opencode_permissions "$profile_json" "$codegen_dir/opencode-permissions.json"
}
