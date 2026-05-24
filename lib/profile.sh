#!/usr/bin/env bash
#
# lib/profile.sh — parse, merge, validate, and normalize .boring/profile.yaml.
#
# Per ARD-0001/0004, the profile is repo state and may be locally overridden by
# .boring/profile.overlay.yaml (gitignored). Overlay wins on conflicts.
# profile_load emits a single normalized JSON blob on stdout that compose.sh,
# egress.sh, and cmd_open consume. Schema fields per ARD-0004.
#
# Secret syntax: env values that start with `secret://` are treated as URIs for
# lib/secrets.sh to resolve; everything else is a literal. The public-facing
# `!secret <uri>` YAML tag form is TODO(impl, ARD-0002) — yq drops custom tags
# when emitting JSON, so a tag-rewrite pre-pass will land when we adopt it.

require_cmd_yq() {
  require_cmd yq "Install: brew install yq  (the Go version from mikefarah/yq, not python-yq)"
  require_cmd jq "Install: brew install jq"
}

# profile_validate <profile-yaml-path>
# Schema-checks one file. No overlay merge, no normalization. Returns 0 if
# valid; logs each violation via log_error and returns 1 if not.
profile_validate() {
  local yaml_path="$1"
  [[ -z "$yaml_path" ]] && die "profile_validate: missing path argument"
  [[ -f "$yaml_path" ]] || die "profile_validate: file not found: $yaml_path"
  require_cmd_yq

  local json
  if ! json="$(yq -o=json '.' "$yaml_path" 2>&1)"; then
    log_error "profile_validate: invalid YAML in $yaml_path: $json"
    return 1
  fi
  _profile_validate_json "$json" "$yaml_path"
}

# profile_load <repo-path>
# Reads .boring/profile.yaml, merges .boring/profile.overlay.yaml if present,
# validates, applies theme presets, prints normalized JSON.
profile_load() {
  local repo="$1"
  [[ -z "$repo" ]] && die "profile_load: missing repo path argument"
  [[ -d "$repo" ]] || die "profile_load: not a directory: $repo"
  require_cmd_yq

  local base="$repo/.boring/profile.yaml"
  local overlay="$repo/.boring/profile.overlay.yaml"
  [[ -f "$base" ]] || die "profile_load: no profile at $base"

  local merged_json
  if [[ -f "$overlay" ]]; then
    # yq's deep-merge idiom; overlay wins on conflicts.
    if ! merged_json="$(yq -o=json eval-all \
        '. as $item ireduce ({}; . * $item)' "$base" "$overlay" 2>&1)"; then
      die "profile_load: failed to merge $overlay onto $base: $merged_json"
    fi
  else
    if ! merged_json="$(yq -o=json '.' "$base" 2>&1)"; then
      die "profile_load: invalid YAML in $base: $merged_json"
    fi
  fi

  _profile_validate_json "$merged_json" "$base" || die "profile_load: schema validation failed"
  _profile_normalize "$merged_json"
}

# _profile_validate_json <json> <source-label>
# Logs each violation; returns non-zero if any were logged.
_profile_validate_json() {
  local json="$1" source="$2" errors=0

  _bump() { ((errors++)) || true; }

  local name theme has_df has_bi services_type ds
  name="$(jq -r '.name // ""' <<<"$json")"
  if [[ -z "$name" ]]; then
    log_error "$source: 'name' is required"; _bump
  elif [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
    log_error "$source: 'name' must be slug-shaped [a-z0-9-]+ (got: $name)"; _bump
  fi

  theme="$(jq -r '.theme // ""' <<<"$json")"
  if [[ -n "$theme" && "$theme" != "shopify" ]]; then
    log_error "$source: unknown theme '$theme' (supported: shopify)"; _bump
  fi

  has_df="$(jq -r '.stack.dockerfile // "" | length > 0' <<<"$json")"
  has_bi="$(jq -r '.stack.base_image // "" | length > 0' <<<"$json")"
  if [[ "$has_df" == "true" && "$has_bi" == "true" ]]; then
    log_error "$source: stack.dockerfile and stack.base_image are mutually exclusive"; _bump
  fi

  services_type="$(jq -r '.services | type' <<<"$json")"
  if [[ "$services_type" == "null" ]]; then
    log_error "$source: 'services' is required (use [] for none)"; _bump
  elif [[ "$services_type" != "array" ]]; then
    log_error "$source: 'services' must be a list (got: $services_type)"; _bump
  fi

  local bad
  bad="$(jq -r '(.mounts // []) | map(select(
      type != "string" or
      (split(":") | length < 2 or length > 3) or
      (split(":") | length == 3 and .[2] != "ro")
    )) | .[]' <<<"$json")"
  if [[ -n "$bad" ]]; then
    while IFS= read -r m; do
      log_error "$source: invalid mount '$m' (expected host_path:container_path[:ro])"; _bump
    done <<<"$bad"
  fi

  bad="$(jq -r '(.forward_ports // []) | map(select(type != "number" or . != (. | floor))) | .[]' <<<"$json")"
  if [[ -n "$bad" ]]; then
    while IFS= read -r p; do
      log_error "$source: forward_ports entry must be integer (got: $p)"; _bump
    done <<<"$bad"
  fi

  ds="$(jq -r '.data_sensitivity // ""' <<<"$json")"
  if [[ -n "$ds" && "$ds" != "internal" && "$ds" != "sanitized" && "$ds" != "public" ]]; then
    log_error "$source: data_sensitivity must be one of internal/sanitized/public (got: $ds)"; _bump
  fi

  bad="$(jq -r '(.env // {}) | to_entries | map(select(
      (.value | type) != "string" and
      ((.value | type) != "object" or
       ((.value | has("value")) | not) and ((.value | has("secret")) | not))
    )) | .[] | .key' <<<"$json")"
  if [[ -n "$bad" ]]; then
    while IFS= read -r k; do
      log_error "$source: env.$k must be a string or {value: ...} or {secret: <uri>}"; _bump
    done <<<"$bad"
  fi

  [[ "$errors" -eq 0 ]]
}

# _profile_normalize <merged-json>
# Tilde-expands mount hosts, classifies env entries as literal vs secret URI,
# fills in theme-preset base_image defaults. Per ARD-0004, other preset bits
# (egress allowlist, mount defaults) are owned by egress.sh / future steps.
_profile_normalize() {
  local json="$1"

  jq -n --argjson p "$json" --arg home "$HOME" '
    def expand_tilde:
      if startswith("~/") then $home + (.[1:]) else . end;

    def parse_mount:
      split(":")
      | { host: (.[0] | expand_tilde),
          container: .[1],
          ro: (length == 3 and .[2] == "ro") };

    def parse_env_value:
      if type == "string" then
        if startswith("secret://") then {kind: "secret", uri: (.[9:])}
        else {kind: "literal", value: .}
        end
      elif type == "object" then
        if has("secret") then {kind: "secret", uri: .secret}
        elif has("value") then {kind: "literal", value: .value}
        else {kind: "literal", value: (. | tostring)}
        end
      else {kind: "literal", value: (. | tostring)}
      end;

    ($p.stack.dockerfile // null) as $df
    | ($p.stack.base_image // null) as $bi
    | ($p.theme // null) as $theme
    | (if $theme == "shopify" and $df == null and $bi == null
         then "boring/shopify-theme:v1" else $bi end) as $resolved_bi
    | {
        name: $p.name,
        theme: $theme,
        stack: { dockerfile: $df, base_image: $resolved_bi },
        services: ($p.services // []),
        mounts: (($p.mounts // []) | map(parse_mount)),
        forward_ports: ($p.forward_ports // []),
        env: (($p.env // {}) | with_entries(.value |= parse_env_value)),
        egress: { allow: ($p.egress.allow // []) },
        data_sensitivity: ($p.data_sensitivity // "internal"),
        guardrails: {
          forbid_branches: ($p.guardrails.forbid_branches // []),
          forbid_commands: ($p.guardrails.forbid_commands // []),
          allowed_claude_tools: ($p.guardrails.allowed_claude_tools // [])
        },
        claude: { mcp: ($p.claude.mcp // []) }
      }
  '
}
