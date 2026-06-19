#!/usr/bin/env bash
#
# lib/profile.sh — parse, merge, validate, and normalize .boring/profile.yaml.
#
# Per ARD-0001/0004, the profile is repo state and may be locally overridden by
# .boring/profile.overlay.yaml (gitignored). Overlay wins on conflicts.
# profile_load emits a single normalized JSON blob on stdout that compose.sh,
# egress.sh, and cmd_open consume. Schema fields per ARD-0004 + ARD-0007.
#
# Secret syntax: env values that start with `secret://` are treated as URIs for
# lib/secrets.sh to resolve; everything else is a literal. The public-facing
# `!secret <uri>` YAML tag form is TODO(impl, ARD-0002) — yq drops custom tags
# when emitting JSON, so a tag-rewrite pre-pass will land when we adopt it.
#
# Schema versioning (ARD-0007): every profile declares `profile_version: "1"`.
# Missing → warn; unknown → hard error. Deprecated fields are walked from
# _BORING_PROFILE_DEPRECATIONS_V1 below — each rename emits a one-line warning
# and is rewritten in-memory so downstream code only ever sees the new name.

# Current schema version. Bump (and add a deprecation table for the prior
# version) when a field is renamed or removed in a breaking way.
BORING_SCHEMA_VERSION="1"

# Deprecation table for v1 schema: "<old_field>:<new_field>" pairs (top-level
# fields only). _profile_rewrite_deprecated walks this list, warns on each old
# field present in the profile, and renames it in-memory to the new field. v2
# schema will error instead of warning. Add entries here, not by editing the
# rewriter.
_BORING_PROFILE_DEPRECATIONS_V1=(
  "theme:preset"
)

# Per ARD-0026: guardrails.allowed_claude_tools: is a deprecated alias for
# guardrails.allowed_tools:. The nested location means the top-level deprecation
# table does not apply; _profile_rewrite_guardrails_deprecated handles it.
_BORING_GUARDRAILS_DEPRECATIONS_V1=(
  "allowed_claude_tools:allowed_tools"
)

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

  _profile_check_version "$merged_json" "$base"
  merged_json="$(_profile_rewrite_deprecated "$merged_json" "$base")"
  merged_json="$(_profile_rewrite_guardrails_deprecated "$merged_json" "$base")"
  _profile_validate_json "$merged_json" "$base" || die "profile_load: schema validation failed"
  _profile_normalize "$merged_json"
}

# _profile_check_version <json> <source-label>
# Enforces profile_version compatibility per ARD-0007.
#   - missing → warn (assume current); we don't refuse to load unversioned
#     legacy profiles in v1, just nudge.
#   - matches BORING_SCHEMA_VERSION → silent.
#   - unknown (future) version → die with an upgrade hint.
_profile_check_version() {
  local json="$1" source="$2"
  local declared
  declared="$(jq -r '.profile_version // ""' <<<"$json")"

  if [[ -z "$declared" ]]; then
    log_warn "$source: profile_version not set; assuming \"$BORING_SCHEMA_VERSION\" (add 'profile_version: \"$BORING_SCHEMA_VERSION\"' to silence)"
    return 0
  fi

  if [[ "$declared" == "$BORING_SCHEMA_VERSION" ]]; then
    return 0
  fi

  # Numeric-aware comparison: if declared > current, the profile was authored
  # against a newer boring; tell the user to upgrade. Otherwise it's an older
  # version we no longer accept (none yet — but the message anticipates v2+).
  if [[ "$declared" =~ ^[0-9]+$ && "$BORING_SCHEMA_VERSION" =~ ^[0-9]+$ ]]; then
    if (( declared > BORING_SCHEMA_VERSION )); then
      die "$source: profile declares profile_version \"$declared\" but this boring only supports up to \"$BORING_SCHEMA_VERSION\". Upgrade boring."
    fi
    die "$source: profile declares profile_version \"$declared\" which is no longer supported by this boring (current: \"$BORING_SCHEMA_VERSION\"). See docs/ards/ for the migration path."
  fi

  die "$source: profile_version must be a major-version string like \"1\" (got: \"$declared\")"
}

# _profile_rewrite_deprecated <json> <source-label>
# Walks _BORING_PROFILE_DEPRECATIONS_V1 ("old:new" pairs). For each old field
# present at the top level of the profile, logs a deprecation warning and
# renames it in-memory to its new key. Conflicts (both old and new set) lose
# the old value loudly. Returns the rewritten JSON on stdout.
_profile_rewrite_deprecated() {
  local json="$1" source="$2"
  local pair old new

  for pair in "${_BORING_PROFILE_DEPRECATIONS_V1[@]}"; do
    old="${pair%%:*}"
    new="${pair##*:}"
    local has_old has_new
    has_old="$(jq --arg k "$old" 'has($k)' <<<"$json")"
    has_new="$(jq --arg k "$new" 'has($k)' <<<"$json")"

    [[ "$has_old" != "true" ]] && continue

    if [[ "$has_new" == "true" ]]; then
      log_warn "$source: field '$old:' is deprecated and was ignored because '$new:' is also set. Remove '$old:'."
      json="$(jq --arg k "$old" 'del(.[$k])' <<<"$json")"
    else
      log_warn "$source: field '$old:' is deprecated; rename to '$new:'."
      json="$(jq --arg o "$old" --arg n "$new" '. + {($n): .[$o]} | del(.[$o])' <<<"$json")"
    fi
  done

  printf '%s' "$json"
}

# _profile_rewrite_guardrails_deprecated <json> <source-label>
# Per ARD-0026: walks _BORING_GUARDRAILS_DEPRECATIONS_V1 against the nested
# guardrails: block. Same warn-and-rename semantics as the top-level rewriter;
# conflicts (both old and new set under guardrails:) are a hard error (the
# top-level rewriter just warns, but tool allowlists are security-relevant so
# we refuse the ambiguity rather than silently dropping one).
_profile_rewrite_guardrails_deprecated() {
  local json="$1" source="$2"
  local pair old new

  for pair in "${_BORING_GUARDRAILS_DEPRECATIONS_V1[@]}"; do
    old="${pair%%:*}"
    new="${pair##*:}"
    local has_old has_new
    has_old="$(jq --arg k "$old" '.guardrails // {} | has($k)' <<<"$json")"
    has_new="$(jq --arg k "$new" '.guardrails // {} | has($k)' <<<"$json")"

    [[ "$has_old" != "true" ]] && continue

    if [[ "$has_new" == "true" ]]; then
      die "$source: guardrails.$old: and guardrails.$new: are both set. Remove the deprecated guardrails.$old: (ARD-0026)."
    fi

    log_warn "$source: field 'guardrails.$old:' is deprecated; rename to 'guardrails.$new:' (ARD-0026). Backward-compat alias will be removed in v2."
    json="$(jq --arg o "$old" --arg n "$new" '
      .guardrails = ((.guardrails // {}) + {($n): (.guardrails[$o])} | del(.[$o]))
    ' <<<"$json")"
  done

  printf '%s' "$json"
}

# _profile_validate_json <json> <source-label>
# Logs each violation; returns non-zero if any were logged.
_profile_validate_json() {
  local json="$1" source="$2" errors=0

  _bump() { ((errors++)) || true; }

  local name preset has_df has_bi services_type ds
  name="$(jq -r '.name // ""' <<<"$json")"
  if [[ -z "$name" ]]; then
    log_error "$source: 'name' is required"; _bump
  elif [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
    log_error "$source: 'name' must be slug-shaped [a-z0-9-]+ (got: $name)"; _bump
  fi

  # Per ARD-0007, `preset:` is the canonical field; `theme:` is deprecated and
  # rewritten upstream of validation by _profile_rewrite_deprecated. So we only
  # ever see `preset:` here. v1.0 preset list locked by ARD-0014.
  preset="$(jq -r '.preset // ""' <<<"$json")"
  case "$preset" in
    ""|shopify|django-node|python|node|node-postgres) ;;
    *)
      log_error "$source: unknown preset '$preset' (supported: shopify, django-node, python, node, node-postgres)"; _bump
      ;;
  esac

  # preset_version (ARD-0014): a flat map { language: "version" } that compose
  # passes through to docker build as --build-arg KEY_VERSION=value. Must be a
  # map; each value must be a non-empty string. Keys are NOT validated against
  # a known list at the validator level — the Dockerfile's ARG declarations
  # are the contract, and an unknown key just becomes an unused build-arg
  # (Docker warns but doesn't error). Surfaces as warning, not error, if set
  # without preset: (the user probably forgot the preset field).
  local pv_type
  pv_type="$(jq -r '.preset_version | type' <<<"$json")"
  if [[ "$pv_type" != "null" ]]; then
    if [[ "$pv_type" != "object" ]]; then
      log_error "$source: 'preset_version' must be a map of {language: \"version\"} (got: $pv_type)"; _bump
    else
      # Values must be non-empty strings restricted to characters that round-trip
      # safely through compose-yaml quoting AND docker --build-arg. Allowed:
      # alphanumerics, dot, dash, underscore, plus. Disallowed: quotes, spaces,
      # backslashes, shell metacharacters. This is wider than realistic version
      # strings need, but tight enough to reject anything that could break the
      # build-args YAML emission downstream.
      local pv_bad
      pv_bad="$(jq -r '
        .preset_version // {}
        | to_entries
        | map(select((.value | type) != "string" or (.value | test("^[A-Za-z0-9._+-]+$") | not)))
        | .[] | .key
      ' <<<"$json")"
      if [[ -n "$pv_bad" ]]; then
        while IFS= read -r k; do
          log_error "$source: preset_version.$k must be a non-empty version string matching [A-Za-z0-9._+-]+ (e.g. \"3.12\")"; _bump
        done <<<"$pv_bad"
      fi
      if [[ -z "$preset" ]]; then
        log_warn "$source: 'preset_version' is set but 'preset' is not — preset_version will be ignored"
      fi
    fi
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
  else
    # Each entry must be an object with at least name + image. name must be
    # slug-shaped (used as compose service name + DNS hostname). volumes are
    # "named:/path" or "/host:/container" strings; env is a flat string map.
    # See ARD-0007 for the structured-services schema rationale.
    local svc_bad
    svc_bad="$(jq -r '
      .services // []
      | to_entries | map(
          . as $entry
          | .value as $svc
          | if ($svc | type) != "object" then "services[\($entry.key)]: not an object"
            elif ($svc.name // "") == "" then "services[\($entry.key)]: missing required field: name"
            elif (($svc.name | type) != "string") or (($svc.name | test("^[a-z0-9-]+$")) | not)
              then "services[\($entry.key)].name: must be slug-shaped [a-z0-9-]+ (got: \"\($svc.name)\")"
            elif ($svc.image // "") == "" then "services.\($svc.name): missing required field: image"
            elif ($svc.env // {} | type) != "object" then "services.\($svc.name).env: must be a map of string→string"
            elif ($svc.volumes // [] | type) != "array" then "services.\($svc.name).volumes: must be a list"
            else empty end
        ) | .[]' <<<"$json")"
    if [[ -n "$svc_bad" ]]; then
      while IFS= read -r m; do
        log_error "$source: $m"; _bump
      done <<<"$svc_bad"
    fi

    # Volume strings: "named:/container/path" (named volume reference) OR
    # "/host/path:/container/path" (bind mount). At minimum, must contain a
    # colon and split into two non-empty parts.
    local vol_bad
    vol_bad="$(jq -r '
      .services // [] | map(
        . as $svc
        | (.volumes // []) | map(
            select(
              type != "string" or
              (split(":") | length != 2) or
              (split(":") | .[0] == "" or .[1] == "")
            ) | "services.\($svc.name).volumes: bad entry \"\(.)\" (expected \"name:/path\" or \"/host:/container\")"
          ) | .[]
      ) | .[]' <<<"$json")"
    if [[ -n "$vol_bad" ]]; then
      while IFS= read -r m; do
        log_error "$source: $m"; _bump
      done <<<"$vol_bad"
    fi
  fi

  # `bad` is reused below across mount/port/env validators. Declare once at the
  # top of these helpers (was previously declared late and then implicitly
  # leaked from the volumes block — bash semantic-leak, not a runtime bug).
  local bad

  # Top-level `volumes:` declares named volumes referenced by services[].volumes.
  # Must be a list of strings (volume names, slug-shaped).
  local vols_type
  vols_type="$(jq -r '.volumes // [] | type' <<<"$json")"
  if [[ "$vols_type" != "array" ]]; then
    log_error "$source: top-level 'volumes' must be a list of strings (got: $vols_type)"; _bump
  else
    bad="$(jq -r '(.volumes // []) | map(select(
      type != "string" or (test("^[a-z0-9-]+$") | not)
    )) | .[]' <<<"$json")"
    if [[ -n "$bad" ]]; then
      while IFS= read -r v; do
        log_error "$source: volume name '$v' must be slug-shaped [a-z0-9-]+"; _bump
      done <<<"$bad"
    fi
  fi

  # `setup:` is a list of shell-command strings, run as postCreateCommand
  # after the dev container is first created. See ARD-0007 §5.
  local setup_type
  setup_type="$(jq -r '.setup // [] | type' <<<"$json")"
  if [[ "$setup_type" != "array" ]]; then
    log_error "$source: 'setup' must be a list of shell-command strings (got: $setup_type)"; _bump
  else
    bad="$(jq -r '(.setup // []) | map(select(type != "string" or . == "")) | .[]' <<<"$json")"
    if [[ -n "$bad" ]]; then
      while IFS= read -r s; do
        log_error "$source: setup entry must be a non-empty string (got: $s)"; _bump
      done <<<"$bad"
    fi
  fi

  # `restore:` is a list of structured entries (ARD-0012). Each entry needs
  # source (dbx URI or storage path) + target (must match a service name) +
  # optional transform + optional when (first_up | every_up | manual).
  # transform: is REQUIRED when data_sensitivity is "sanitized" — the safety
  # contract from ARD-0001 §"Security — data sensitivity" that's been
  # designed-but-no-op since v0.2.
  local restore_type sensitivity
  restore_type="$(jq -r '.restore // [] | type' <<<"$json")"
  sensitivity="$(jq -r '.data_sensitivity // "internal"' <<<"$json")"
  if [[ "$restore_type" != "array" ]]; then
    log_error "$source: 'restore' must be a list of restore entries (got: $restore_type)"; _bump
  elif [[ "$sensitivity" == "internal" ]]; then
    # ARD-0012 §3: restore is incompatible with data_sensitivity: internal —
    # internal means "no real data ever in this container."
    local count
    count="$(jq -r '(.restore // []) | length' <<<"$json")"
    if [[ "$count" -gt 0 ]]; then
      log_error "$source: 'restore' entries require data_sensitivity to be 'sanitized' or 'public' (current: 'internal'). Set data_sensitivity explicitly per ARD-0012."; _bump
    fi
  else
    # Validate each entry's shape and the transform: interlock. Error
    # messages avoid apostrophes — they'd terminate the bash single-quoted
    # jq script and bash would then try to execute the angle-bracketed
    # placeholder names as shell.
    local rs_bad
    rs_bad="$(jq -r --arg sens "$sensitivity" '
      def valid_when: . == "first_up" or . == "every_up" or . == "manual";
      .restore // []
      | to_entries | map(
          . as $entry | .value as $r
          | if ($r | type) != "object" then "restore[\($entry.key)]: not an object"
            elif ($r.source // "") == "" then "restore[\($entry.key)]: missing required field: source"
            elif ($r.target // "") == "" then "restore[\($entry.key)]: missing required field: target"
            elif (($r.target | type) != "string") or (($r.target | test("^[a-z0-9-]+$")) | not)
              then "restore[\($entry.key)].target: must be slug-shaped [a-z0-9-]+ (got: " + ($r.target | tostring) + ")"
            elif (($r.when // "first_up") | valid_when | not)
              then "restore[\($entry.key)].when: must be one of first_up|every_up|manual (got: " + ($r.when | tostring) + ")"
            elif ($sens == "sanitized") and (($r.transform // "") == "")
              then "restore[\($entry.key)]: transform field required when data_sensitivity is sanitized (ARD-0012). Add a transform: path/to/sanitizer or set data_sensitivity: public if the data is non-sensitive."
            else empty end
        ) | .[]' <<<"$json")"
    if [[ -n "$rs_bad" ]]; then
      while IFS= read -r m; do
        log_error "$source: $m"; _bump
      done <<<"$rs_bad"
    fi

    # Cross-reference: every restore.target must match a service.name.
    # Single-jq with both lists in scope; no embedded quote escaping.
    local missing
    missing="$(jq -r '
      . as $p
      | ($p.services // [] | map(.name)) as $names
      | ($p.restore // []) | to_entries
      | map(. as $e | select(($names | index($e.value.target)) == null))
      | map("restore[" + (.key | tostring) + "].target: " + .value.target + " not found in services")
      | .[]' <<<"$json")"
    if [[ -n "$missing" ]]; then
      while IFS= read -r m; do
        log_error "$source: $m"; _bump
      done <<<"$missing"
    fi
  fi

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

  # ARD-0010 §4: audit.prompts is per_user|shared, default per_user. The default
  # is conservative — sharing prompts profile-wide is an explicit opt-in. Security
  # events are not configurable: they are always profile-shared.
  local audit_prompts
  audit_prompts="$(jq -r '.audit.prompts // ""' <<<"$json")"
  if [[ -n "$audit_prompts" && "$audit_prompts" != "per_user" && "$audit_prompts" != "shared" ]]; then
    log_error "$source: audit.prompts must be one of per_user/shared (got: $audit_prompts)"; _bump
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

  # ARD-0026 + ARD-0022: allowed_paths: / disallowed_paths: are top-level lists
  # of glob patterns. Each entry must be a non-empty string; bare leading
  # tildes and `..` are rejected (paths are repo-relative, not host-relative).
  local path_field_type
  for field in allowed_paths disallowed_paths; do
    path_field_type="$(jq -r --arg f "$field" '.[$f] // [] | type' <<<"$json")"
    if [[ "$path_field_type" != "array" ]]; then
      log_error "$source: '$field' must be a list of glob patterns (got: $path_field_type)"; _bump
      continue
    fi
    bad="$(jq -r --arg f "$field" '(.[$f] // []) | map(select(
        type != "string" or . == "" or startswith("/") or startswith("~") or contains("..")
      )) | .[]' <<<"$json")"
    if [[ -n "$bad" ]]; then
      while IFS= read -r p; do
        log_error "$source: $field entry must be a non-empty repo-relative glob (got: $p)"; _bump
      done <<<"$bad"
    fi
  done

  # ARD-0022 §6: preview_url: and preview_urls: are mutually exclusive. preview_url
  # is a single string; preview_urls is a list of {name, url} objects.
  local has_pu has_pus
  has_pu="$(jq -r 'has("preview_url")' <<<"$json")"
  has_pus="$(jq -r 'has("preview_urls")' <<<"$json")"
  if [[ "$has_pu" == "true" && "$has_pus" == "true" ]]; then
    log_error "$source: 'preview_url' and 'preview_urls' are mutually exclusive"; _bump
  fi
  if [[ "$has_pu" == "true" ]]; then
    local pu pu_type
    pu_type="$(jq -r '.preview_url | type' <<<"$json")"
    pu="$(jq -r '.preview_url // ""' <<<"$json")"
    if [[ "$pu_type" != "string" || -z "$pu" ]]; then
      log_error "$source: 'preview_url' must be a non-empty string (got type: $pu_type)"; _bump
    fi
  fi
  if [[ "$has_pus" == "true" ]]; then
    local pus_type
    pus_type="$(jq -r '.preview_urls | type' <<<"$json")"
    if [[ "$pus_type" != "array" ]]; then
      log_error "$source: 'preview_urls' must be a list of {name, url} objects (got: $pus_type)"; _bump
    else
      bad="$(jq -r '.preview_urls | to_entries | map(
          . as $e | .value as $v
          | if ($v | type) != "object" then "preview_urls[\($e.key)]: not an object"
            elif (($v.name // "") == "") or (($v.name | type) != "string")
              then "preview_urls[\($e.key)]: missing or non-string name"
            elif (($v.url // "") == "") or (($v.url | type) != "string")
              then "preview_urls[\($e.key)]: missing or non-string url"
            else empty end
        ) | .[]' <<<"$json")"
      if [[ -n "$bad" ]]; then
        while IFS= read -r m; do
          log_error "$source: $m"; _bump
        done <<<"$bad"
      fi
    fi
  fi

  # ARD-0022 §7: save: block. All fields optional; type-check those present.
  # reviewers_from: and reviewers: are mutually exclusive.
  local save_type
  save_type="$(jq -r '.save // null | if . == null then "null" else type end' <<<"$json")"
  if [[ "$save_type" != "null" && "$save_type" != "object" ]]; then
    log_error "$source: 'save' must be a map (got: $save_type)"; _bump
  elif [[ "$save_type" == "object" ]]; then
    local has_rf has_rl
    has_rf="$(jq -r '.save | has("reviewers_from")' <<<"$json")"
    has_rl="$(jq -r '.save | has("reviewers")' <<<"$json")"
    if [[ "$has_rf" == "true" && "$has_rl" == "true" ]]; then
      log_error "$source: 'save.reviewers_from' and 'save.reviewers' are mutually exclusive"; _bump
    fi
    bad="$(jq -r '
      .save as $s
      | [
          (if ($s | has("target_branch"))   and (($s.target_branch | type)   != "string") then "save.target_branch must be a string" else empty end),
          (if ($s | has("reviewers_from"))  and ($s.reviewers_from != "codeowners")       then "save.reviewers_from must be \"codeowners\" (got: " + ($s.reviewers_from | tostring) + ")" else empty end),
          (if ($s | has("draft_by_default"))and (($s.draft_by_default | type) != "boolean")then "save.draft_by_default must be a boolean" else empty end),
          (if ($s | has("branch_prefix"))   and (($s.branch_prefix | type)   != "string") then "save.branch_prefix must be a string" else empty end),
          (if ($s | has("pr_template"))     and (($s.pr_template | type)     != "string") then "save.pr_template must be a string" else empty end),
          (if ($s | has("reviewers"))       and (($s.reviewers | type)       != "array")  then "save.reviewers must be a list of strings" else empty end)
        ] | .[]' <<<"$json")"
    if [[ -n "$bad" ]]; then
      while IFS= read -r m; do
        log_error "$source: $m"; _bump
      done <<<"$bad"
    fi
    # If reviewers: is a list, every entry must be a non-empty string.
    if [[ "$has_rl" == "true" ]]; then
      bad="$(jq -r '(.save.reviewers // []) | map(select(type != "string" or . == "")) | .[]' <<<"$json")"
      if [[ -n "$bad" ]]; then
        while IFS= read -r r; do
          log_error "$source: save.reviewers entry must be a non-empty string (got: $r)"; _bump
        done <<<"$bad"
      fi
    fi
  fi

  # ARD-0022 §3 + §7.3: wip_branch_ttl: / wip_branch_grace: are duration strings
  # like 7d, 24h, 30m. Accept Nd|Nh|Nm patterns (integer + unit). Reject anything
  # else; codegen depends on the parsed shape.
  local dur
  for field in wip_branch_ttl wip_branch_grace; do
    dur="$(jq -r --arg f "$field" '.[$f] // ""' <<<"$json")"
    if [[ -n "$dur" && ! "$dur" =~ ^[0-9]+[dhm]$ ]]; then
      log_error "$source: $field must be a duration like 7d, 24h, or 30m (got: $dur)"; _bump
    fi
  done

  # v0.9.0 (ARD-0030): top-level `dev:` block — long-running dev command run in
  # foreground by `boring open` after the container is up + setup is complete +
  # (when --ui) the UI stack is started. Required field: dev.command (string OR
  # list-of-strings; list is joined with spaces). Optional: dev.workdir
  # (container-side path, must start with /; default /workspace) and dev.port
  # (informational only; forward_ports is the real port config).
  local dev_type
  dev_type="$(jq -r '.dev // null | if . == null then "null" else type end' <<<"$json")"
  if [[ "$dev_type" != "null" && "$dev_type" != "object" ]]; then
    log_error "$source: 'dev' must be a map (got: $dev_type)"; _bump
  elif [[ "$dev_type" == "object" ]]; then
    local dev_cmd_type dev_workdir dev_workdir_type dev_port_raw
    dev_cmd_type="$(jq -r '.dev | if has("command") then (.command | type) else "absent" end' <<<"$json")"
    case "$dev_cmd_type" in
      string)
        # Empty string is not a valid command.
        local dev_cmd_str
        dev_cmd_str="$(jq -r '.dev.command' <<<"$json")"
        [[ -z "$dev_cmd_str" ]] && { log_error "$source: dev.command must be a non-empty string"; _bump; }
        ;;
      array)
        # Must be non-empty and every entry must be a non-empty string.
        local dev_cmd_len
        dev_cmd_len="$(jq -r '.dev.command | length' <<<"$json")"
        if [[ "$dev_cmd_len" -eq 0 ]]; then
          log_error "$source: dev.command list must contain at least one entry"; _bump
        else
          bad="$(jq -r '.dev.command | map(select(type != "string" or . == "")) | .[]' <<<"$json")"
          if [[ -n "$bad" ]]; then
            while IFS= read -r v; do
              log_error "$source: dev.command list entries must be non-empty strings (got: $v)"; _bump
            done <<<"$bad"
          fi
        fi
        ;;
      absent)
        log_error "$source: dev.command is required when 'dev:' block is present"; _bump
        ;;
      *)
        log_error "$source: dev.command must be a string or list of strings (got: $dev_cmd_type)"; _bump
        ;;
    esac
    dev_workdir_type="$(jq -r '.dev | if has("workdir") then (.workdir | type) else "absent" end' <<<"$json")"
    if [[ "$dev_workdir_type" != "absent" ]]; then
      if [[ "$dev_workdir_type" != "string" ]]; then
        log_error "$source: dev.workdir must be a string (got: $dev_workdir_type)"; _bump
      else
        dev_workdir="$(jq -r '.dev.workdir' <<<"$json")"
        if [[ -z "$dev_workdir" || "${dev_workdir:0:1}" != "/" ]]; then
          log_error "$source: dev.workdir must be an absolute container-side path starting with / (got: $dev_workdir)"; _bump
        fi
      fi
    fi
    # dev.port: integer 1..65535 if present. Informational only; forward_ports
    # is the canonical port-forward config — we do not auto-add this to it.
    local dev_port_type
    dev_port_type="$(jq -r '.dev | if has("port") then (.port | type) else "absent" end' <<<"$json")"
    if [[ "$dev_port_type" != "absent" ]]; then
      if [[ "$dev_port_type" != "number" ]]; then
        log_error "$source: dev.port must be an integer (got: $dev_port_type)"; _bump
      else
        dev_port_raw="$(jq -r '.dev.port' <<<"$json")"
        if ! [[ "$dev_port_raw" =~ ^[0-9]+$ ]] || [[ "$dev_port_raw" -lt 1 || "$dev_port_raw" -gt 65535 ]]; then
          log_error "$source: dev.port must be an integer between 1 and 65535 (got: $dev_port_raw)"; _bump
        fi
      fi
    fi
  fi

  # v0.8.0 (boring open --ui): top-level `ui:` block, all optional.
  #   ui.enabled (bool, default false) — opt-in trigger for `boring open` to
  #     bring up the boring-ui web stack after the container is up.
  #   ui.preview_url (string) — absolute URL the right-pane iframe loads.
  #     Wins over top-level preview_url when both set (UI is the only consumer).
  local ui_type
  ui_type="$(jq -r '.ui // null | if . == null then "null" else type end' <<<"$json")"
  if [[ "$ui_type" != "null" && "$ui_type" != "object" ]]; then
    log_error "$source: 'ui' must be a map (got: $ui_type)"; _bump
  elif [[ "$ui_type" == "object" ]]; then
    local ui_enabled_type ui_preview_type ui_preview
    ui_enabled_type="$(jq -r '.ui | if has("enabled") then (.enabled | type) else "absent" end' <<<"$json")"
    if [[ "$ui_enabled_type" != "absent" && "$ui_enabled_type" != "boolean" ]]; then
      log_error "$source: ui.enabled must be a boolean (got: $ui_enabled_type)"; _bump
    fi
    ui_preview_type="$(jq -r '.ui | if has("preview_url") then (.preview_url | type) else "absent" end' <<<"$json")"
    if [[ "$ui_preview_type" != "absent" ]]; then
      if [[ "$ui_preview_type" != "string" ]]; then
        log_error "$source: ui.preview_url must be a string URL (got: $ui_preview_type)"; _bump
      else
        ui_preview="$(jq -r '.ui.preview_url' <<<"$json")"
        # Permissive URL shape — same posture as the top-level preview_url check
        # (non-empty string is enough; we don't gold-plate URL validation).
        [[ -z "$ui_preview" ]] && { log_error "$source: ui.preview_url must be non-empty"; _bump; }
      fi
    fi

    # ARD-0035: ui.agents — optional list of agent tabs for boring-ui's left
    # pane. Absent → default [{name: "claude", harness: "claude"}] (v0.12.0
    # behavior preserved). When present, must be a non-empty array of
    # {name, harness} objects. The two-harness ceiling from ARD-0035 §6 is
    # enforced at the schema layer: harness ∈ {claude, codex}. Adding a third
    # would put us back inside ARD-0020 §1's rejection of per-CLI adapters
    # for three CLIs — the rejection is the load-bearing part of ARD-0035.
    local ui_agents_type
    ui_agents_type="$(jq -r '.ui | if has("agents") then (.agents | type) else "absent" end' <<<"$json")"
    if [[ "$ui_agents_type" != "absent" ]]; then
      if [[ "$ui_agents_type" != "array" ]]; then
        log_error "$source: ui.agents must be a list (got: $ui_agents_type)"; _bump
      else
        local ui_agents_count
        ui_agents_count="$(jq -r '.ui.agents | length' <<<"$json")"
        if [[ "$ui_agents_count" -eq 0 ]]; then
          # Empty list is almost certainly a mistake — the omit path is the
          # "disable" signal. Failing fast surfaces the typo immediately.
          log_error "$source: ui.agents must declare at least one agent (omit the field entirely for the default single-Claude setup)"; _bump
        else
          # Per-entry shape: object with required name (slug-shape) + harness
          # (claude | codex). Mirrors the services: validator at lines
          # 269-283. Names also have to be unique across the list — see the
          # group_by check below — because lib/web_ui.sh allocates ttyd
          # ports by hashing "$slug:$agent_name"; duplicate names collide.
          local agent_bad
          agent_bad="$(jq -r '
            .ui.agents // []
            | to_entries | map(
                . as $entry
                | .value as $a
                | if ($a | type) != "object"
                    then "ui.agents[\($entry.key)]: not an object"
                  elif ($a.name // "") == ""
                    then "ui.agents[\($entry.key)]: missing required field: name"
                  elif (($a.name | type) != "string") or (($a.name | test("^[a-z0-9-]+$")) | not)
                    then "ui.agents[\($entry.key)].name: must be slug-shaped [a-z0-9-]+ (got: \"\($a.name)\")"
                  elif ($a.harness // "") == ""
                    then "ui.agents.\($a.name): missing required field: harness"
                  elif (($a.harness | type) != "string") or (($a.harness == "claude" or $a.harness == "codex") | not)
                    then "ui.agents.\($a.name).harness: must be one of [claude, codex] (got: \"\($a.harness)\"; per ARD-0035 §6 the two-harness ceiling rejects others at the schema layer)"
                  else empty
                  end
              ) | .[]' <<<"$json")"
          if [[ -n "$agent_bad" ]]; then
            while IFS= read -r m; do
              log_error "$source: $m"; _bump
            done <<<"$agent_bad"
          fi

          # Names must be unique across the list.
          local dup_names
          dup_names="$(jq -r '
            .ui.agents // []
            | map(.name | select(. != null and . != ""))
            | group_by(.)
            | map(select(length > 1) | .[0])
            | .[]' <<<"$json")"
          if [[ -n "$dup_names" ]]; then
            while IFS= read -r n; do
              log_error "$source: ui.agents: duplicate agent name '$n' (names must be unique — they are the per-agent ttyd port suffix)"; _bump
            done <<<"$dup_names"
          fi
        fi
      fi
    fi
  fi

  # ARD-0026: guardrails.allowed_tools: must be a list of canonical-name strings.
  # The deprecated guardrails.allowed_claude_tools: alias is rewritten to
  # allowed_tools: in _profile_rewrite_guardrails_deprecated; by validate time
  # only allowed_tools: should be set.
  local at_type
  at_type="$(jq -r '.guardrails.allowed_tools // [] | type' <<<"$json")"
  if [[ "$at_type" != "array" ]]; then
    log_error "$source: guardrails.allowed_tools must be a list of canonical tool names (got: $at_type)"; _bump
  else
    bad="$(jq -r '(.guardrails.allowed_tools // []) | map(select(type != "string" or . == "")) | .[]' <<<"$json")"
    if [[ -n "$bad" ]]; then
      while IFS= read -r t; do
        log_error "$source: guardrails.allowed_tools entry must be a non-empty string (got: $t)"; _bump
      done <<<"$bad"
    fi
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

    def normalize_service:
      {
        name: .name,
        image: .image,
        env: (.env // {}),
        volumes: (.volumes // []),
        healthcheck: (.healthcheck // null),
        depends_on: (.depends_on // [])
      };

    # Preset defaults (ARD-0007 sections 1 and 4). Applied AFTER user values
    # are normalized; user-authored fields win on conflict. For arrays
    # (services, volumes, forward_ports), a user-supplied value either fully
    # replaces the default (when non-empty) or inherits the default (when
    # empty/absent). For env, defaults are merged with user values winning
    # per-key.
    def preset_django_node_defaults:
      {
        services: [{
          name: "postgres",
          image: "postgres:17",
          env: {
            POSTGRES_DB: "content_infra",
            POSTGRES_PASSWORD: "postgres"
          },
          volumes: ["postgres-data:/var/lib/postgresql/data"],
          healthcheck: {
            test: ["CMD", "pg_isready", "-U", "postgres"],
            interval: "5s",
            retries: 10
          },
          depends_on: []
        }],
        volumes: ["postgres-data"],
        forward_ports: [8000, 5173],
        env: {
          DATABASE_URL: {kind: "literal", value: "postgres://postgres:postgres@postgres:5432/content_infra"}
        }
      };

    # ARD-0014: node-postgres mirrors django-node sans the Django specifics.
    # Same postgres sidecar shape, DB name keyed off the preset purpose, and
    # default forward_ports tuned for the common Node-app shape (3000 covers
    # Next.js/Express/Hono default; users override via forward_ports:).
    def preset_node_postgres_defaults:
      {
        services: [{
          name: "postgres",
          image: "postgres:17",
          env: {
            POSTGRES_DB: "app",
            POSTGRES_PASSWORD: "postgres"
          },
          volumes: ["postgres-data:/var/lib/postgresql/data"],
          healthcheck: {
            test: ["CMD", "pg_isready", "-U", "postgres"],
            interval: "5s",
            retries: 10
          },
          depends_on: []
        }],
        volumes: ["postgres-data"],
        forward_ports: [3000],
        env: {
          DATABASE_URL: {kind: "literal", value: "postgres://postgres:postgres@postgres:5432/app"}
        }
      };

    def apply_preset($preset):
      if $preset == "django-node" then
        preset_django_node_defaults as $d
        | . + {
            services:      (if ((.services // []) | length) == 0      then $d.services      else .services end),
            volumes:       (if ((.volumes // []) | length) == 0       then $d.volumes       else .volumes end),
            forward_ports: (if ((.forward_ports // []) | length) == 0 then $d.forward_ports else .forward_ports end),
            env:           ($d.env + (.env // {}))
          }
      elif $preset == "node-postgres" then
        preset_node_postgres_defaults as $d
        | . + {
            services:      (if ((.services // []) | length) == 0      then $d.services      else .services end),
            volumes:       (if ((.volumes // []) | length) == 0       then $d.volumes       else .volumes end),
            forward_ports: (if ((.forward_ports // []) | length) == 0 then $d.forward_ports else .forward_ports end),
            env:           ($d.env + (.env // {}))
          }
      # Pure python and pure node presets intentionally do not seed sidecars or
      # default ports — they are single-language sandboxes (ARD-0014). A
      # profile that wants a DB or extra services declares them explicitly.
      else .
      end;

    # ARD-0022 §6: preview_url/preview_urls normalized into a single shape
    # downstream code can read: a list of {name, url}. preview_url folds into
    # a one-element list with name="default".
    def normalize_preview:
      if $p | has("preview_urls") then ($p.preview_urls // [])
      elif $p | has("preview_url") then [{name: "default", url: $p.preview_url}]
      else [] end;

    # ARD-0022 §7: save block defaults. All keys present in output; missing
    # input keys take the documented defaults. reviewers/reviewers_from are
    # mutually exclusive (validator enforces); the unset one is null here.
    def normalize_save:
      ($p.save // {}) as $s
      | {
          target_branch:    ($s.target_branch    // "main"),
          reviewers_from:   ($s.reviewers_from   // null),
          reviewers:        ($s.reviewers        // null),
          draft_by_default: (if $s | has("draft_by_default") then $s.draft_by_default else true end),
          branch_prefix:    ($s.branch_prefix    // "marketer/"),
          pr_template:      ($s.pr_template      // null)
        };

    ($p.stack.dockerfile // null) as $df
    | ($p.stack.base_image // null) as $bi
    | ($p.preset // null) as $preset
    | (if $preset == "shopify" and $df == null and $bi == null
         then "boring/shopify-theme:v1"
       elif $preset == "django-node" and $df == null and $bi == null
         then "boring/django-node:v1"
       elif $preset == "python" and $df == null and $bi == null
         then "boring/python:v1"
       elif $preset == "node" and $df == null and $bi == null
         then "boring/node:v1"
       elif $preset == "node-postgres" and $df == null and $bi == null
         then "boring/node-postgres:v1"
       else $bi end) as $resolved_bi
    | {
        name: $p.name,
        profile_version: ($p.profile_version // "1"),
        preset: $preset,
        preset_version: ($p.preset_version // {}),
        stack: { dockerfile: $df, base_image: $resolved_bi },
        services: (($p.services // []) | map(normalize_service)),
        volumes: ($p.volumes // []),
        setup: ($p.setup // []),
        restore: (($p.restore // []) | map({
          source: .source,
          target: .target,
          transform: (.transform // null),
          when: (.when // "first_up")
        })),
        mounts: (($p.mounts // []) | map(parse_mount)),
        forward_ports: ($p.forward_ports // []),
        env: (($p.env // {}) | with_entries(.value |= parse_env_value)),
        egress: { allow: ($p.egress.allow // []) },
        data_sensitivity: ($p.data_sensitivity // "internal"),
        guardrails: {
          forbid_branches: ($p.guardrails.forbid_branches // []),
          forbid_commands: ($p.guardrails.forbid_commands // []),
          # Per ARD-0026: allowed_tools is canonical; allowed_claude_tools is
          # kept as a mirror for one minor-version cycle so existing codegen
          # that reads allowed_claude_tools keeps working unchanged.
          allowed_tools: ($p.guardrails.allowed_tools // []),
          allowed_claude_tools: ($p.guardrails.allowed_tools // [])
        },
        # ARD-0026 + ARD-0022: path allowlist as profile-level lists. Preset
        # defaults are merged in guardrails_resolve_paths (lib/guardrails.sh)
        # at codegen time — not here, to keep normalize a pure data shaping.
        allowed_paths:    ($p.allowed_paths    // []),
        disallowed_paths: ($p.disallowed_paths // []),
        # ARD-0022 §6 + §7: boring-ui session/save fields.
        preview_urls: normalize_preview,
        save: normalize_save,
        wip_branch_ttl:   ($p.wip_branch_ttl   // "7d"),
        wip_branch_grace: ($p.wip_branch_grace // "24h"),
        audit: {
          prompts: ($p.audit.prompts // "per_user")
        },
        # v0.8.0: ui block normalized with defaults. ui.preview_url wins over
        # top-level preview_url for the UI iframe (consumer chooses; we just
        # surface both shapes so cmd_open can pick).
        # v0.13.0 (ARD-0035): ui.agents defaulted to a single Claude tab when
        # absent, so downstream code in web_ui.sh + boring-ui-backend can
        # iterate uniformly without special-casing the v0.12.0 single-agent
        # shape. Single-entry lists are still valid and render no tab strip
        # in the UI (web_ui.sh and the frontend treat len==1 as the legacy
        # single-pane case).
        ui: {
          enabled: ($p.ui.enabled // false),
          preview_url: ($p.ui.preview_url // null),
          agents: ($p.ui.agents // [{name: "claude", harness: "claude"}])
        },
        # v0.9.0 (ARD-0030): dev block normalized into {command, workdir, port}.
        # command is always a string downstream (a list is joined with spaces).
        # When the user has not declared a dev: block at all, .dev is null so
        # cmd_open can cheaply skip ("no foreground dev command, drop into
        # bash"). When declared, .dev.command is guaranteed non-empty by the
        # validator above; .dev.workdir defaults to /workspace; .dev.port stays
        # null when absent.
        dev: (if ($p.dev // null) == null then null else
          {
            command: (
              if ($p.dev.command | type) == "array"
                then ($p.dev.command | join(" "))
                else $p.dev.command
              end
            ),
            workdir: ($p.dev.workdir // "/workspace"),
            port:    ($p.dev.port    // null)
          }
        end),
        claude: { mcp: ($p.claude.mcp // []) }
      }
      | apply_preset($preset)
  '
}

# profile_setup_command <normalized-profile-json>
# Single source for the ARD-0007 §5 setup shell-string. Emits the chain that
# runs each `setup:` entry under `set -e`, bracketed by the marker dance
# (create /var/lib/boring, run setup, touch setup-complete on success).
# Empty when the profile declares no setup. Used by both compose.sh (writes
# it into devcontainer.json's postCreateCommand) and cmd_open's re-run path
# (passes it to bash -lc via devcontainer exec).
profile_setup_command() {
  local profile_json="$1"
  jq -r '
    if ((.setup // []) | length) == 0 then ""
    else
      ["set -e", "sudo mkdir -p /var/lib/boring"]
      + (.setup // [])
      + ["sudo touch /var/lib/boring/setup-complete"]
      | join("; ")
    end
  ' <<<"$profile_json"
}
