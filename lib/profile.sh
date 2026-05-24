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

# Deprecation table for v1 schema: "<old_field>:<new_field>" pairs.
# _profile_rewrite_deprecated walks this list, warns on each old field present
# in the profile, and renames it in-memory to the new field. v2 schema will
# error instead of warning. Add entries here, not by editing the rewriter.
_BORING_PROFILE_DEPRECATIONS_V1=(
  "theme:preset"
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
        audit: {
          prompts: ($p.audit.prompts // "per_user")
        },
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
