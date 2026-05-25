#!/usr/bin/env bash
#
# lib/saver.sh — boring-ui save flow + per-turn WIP-branch auto-commit machinery.
#
# Implements ARD-0022 §3 (hidden auto-branching, per-turn commits) and §7 (save
# mechanics: cumulative WIP → named branch → PR). Harness-independent — same
# git plumbing whether claude or opencode drove the file edits.
#
# Three call sites in mind:
#   1. `boring wip start/commit/discard <profile>` — manual CLI driver, useful
#      for engineers debugging and as the v0 stand-in for the in-container
#      backend that will eventually fork-exec these commands per-turn.
#   2. `boring save <profile>` — promotes the WIP branch to a named PR.
#   3. The future boring-ui backend (out of scope here) shelling out to the
#      same `boring` subcommands per turn / per save click.
#
# AI-summarization is a stub (saver_summarize_turn / saver_summarize_pr): if
# `claude --print` is on PATH, shell to it with a 10s timeout; otherwise fall
# back to a deterministic heuristic. Replaced when OpenCode lands per ARD-0020.

# ============================================================================
# Branch naming
# ============================================================================

# saver_wip_branch_name <marketer> <session-resume-ts>
# Returns the canonical WIP branch name per ARD-0022 §3.
saver_wip_branch_name() {
  local marketer="$1" ts="$2"
  [[ -z "$marketer" ]] && die "saver_wip_branch_name: missing <marketer>"
  [[ -z "$ts" ]] && die "saver_wip_branch_name: missing <session-resume-ts>"
  printf 'boring/wip/%s/%s' "$marketer" "$ts"
}

# ============================================================================
# WIP-branch lifecycle (create / commit / discard)
# ============================================================================

# saver_create_wip_branch <repo-path> <branch-name> <base-branch>
# Idempotent: if branch exists, checks out to it; if working tree is dirty,
# refuses with a clear error (a dirty tree would silently mix the marketer's
# uncommitted experiments into the next turn's commit).
saver_create_wip_branch() {
  local repo="$1" branch="$2" base="$3"
  [[ -z "$repo" ]]   && die "saver_create_wip_branch: missing <repo-path>"
  [[ -z "$branch" ]] && die "saver_create_wip_branch: missing <branch-name>"
  [[ -z "$base" ]]   && die "saver_create_wip_branch: missing <base-branch>"
  [[ -d "$repo/.git" ]] || die "saver_create_wip_branch: not a git repo: $repo"
  require_cmd git

  # Refuse if the working tree has uncommitted changes — silently rolling them
  # into a fresh WIP branch would muddy the per-turn audit trail.
  if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
    die "saver_create_wip_branch: working tree dirty at $repo; commit, stash, or reset before starting a WIP branch"
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    log_info "saver: branch $branch already exists; checking out"
    git -C "$repo" checkout "$branch" >/dev/null
    return 0
  fi

  # Validate that the base ref exists locally; an unknown base would create the
  # branch from HEAD with a warning, which is the wrong silent default.
  if ! git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null; then
    die "saver_create_wip_branch: base branch not found: $base (did you forget to fetch?)"
  fi

  log_info "saver: creating WIP branch $branch from $base"
  git -C "$repo" checkout -b "$branch" "$base" >/dev/null
}

# saver_commit_turn <repo-path> <message>
# `git add -A && git commit -m <msg>`; emits the commit SHA on stdout. Exits 0
# with an "no changes" log line if the tree is clean (a non-file-modifying
# turn — ARD-0022 §3 says these are silently skipped, not errors).
saver_commit_turn() {
  local repo="$1" message="$2"
  [[ -z "$repo" ]]    && die "saver_commit_turn: missing <repo-path>"
  [[ -z "$message" ]] && die "saver_commit_turn: missing <message>"
  [[ -d "$repo/.git" ]] || die "saver_commit_turn: not a git repo: $repo"
  require_cmd git

  git -C "$repo" add -A
  if git -C "$repo" diff --cached --quiet; then
    log_info "saver: no changes to commit"
    return 0
  fi

  # `--no-verify` is intentional: per-turn commits should not be gated on
  # repo-side commit hooks. The PR open at save time runs against an aggregate
  # branch; that is where lint/test enforcement belongs.
  git -C "$repo" commit --no-verify -m "$message" >/dev/null

  local sha
  sha="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' "$sha"
}

# saver_discard_wip <repo-path> <branch-name> [--force]
# Deletes the WIP branch. Safety: if the branch has commits not present on its
# upstream / merge-base, refuse unless --force is set. ARD-0022 §3: the
# marketer-visible "I changed my mind" flow goes through this with --force.
saver_discard_wip() {
  local repo="$1" branch="$2" force_flag="${3:-}"
  [[ -z "$repo" ]]   && die "saver_discard_wip: missing <repo-path>"
  [[ -z "$branch" ]] && die "saver_discard_wip: missing <branch-name>"
  [[ -d "$repo/.git" ]] || die "saver_discard_wip: not a git repo: $repo"
  require_cmd git

  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    log_info "saver: branch $branch does not exist; nothing to discard"
    return 0
  fi

  # Don't blow away unsaved work silently. fork-point against main (or the
  # configured target_branch — caller passes the WIP, not the target, so we
  # fall back to "any commits unique to the branch" as the safety check).
  local ahead
  ahead="$(git -C "$repo" rev-list --count "main..$branch" 2>/dev/null || echo "0")"
  if [[ "$ahead" -gt 0 && "$force_flag" != "--force" ]]; then
    die "saver_discard_wip: branch $branch has $ahead unsaved commit(s) ahead of main. Pass --force to delete anyway."
  fi

  # Checkout off the branch before deleting (git refuses to delete the current
  # branch). Best-effort fallback to main, then to the first available branch.
  local current
  current="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  if [[ "$current" == "$branch" ]]; then
    if git -C "$repo" show-ref --verify --quiet "refs/heads/main"; then
      git -C "$repo" checkout main >/dev/null
    else
      local other
      other="$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | grep -vx "$branch" | head -n 1)"
      [[ -n "$other" ]] || die "saver_discard_wip: cannot leave branch $branch (no other branches in repo)"
      git -C "$repo" checkout "$other" >/dev/null
    fi
  fi

  log_info "saver: deleting WIP branch $branch"
  git -C "$repo" branch -D "$branch" >/dev/null
}

# ============================================================================
# AI-summarization stubs (ARD-0022 §7.2)
# ============================================================================
#
# Both summarizers follow the same shape: try `claude --print` with a 10s
# timeout; fall back to a heuristic; always return SOMETHING; never error.
# Replaced when OpenCode lands per ARD-0020.

# _saver_have_claude — quiet check for an executable `claude` on PATH.
_saver_have_claude() {
  command -v claude >/dev/null 2>&1
}

# _saver_have_timeout — `timeout` (GNU coreutils) vs `gtimeout` (Homebrew on
# macOS); returns 0 with the binary name on stdout, or 1 if neither is found.
_saver_have_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"; return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"; return 0
  fi
  return 1
}

# saver_summarize_turn <repo-path> <prompt-text>
# One-line commit-message subject for the turn. 50-char target, imperative
# voice, no trailing period. Output guaranteed non-empty.
saver_summarize_turn() {
  local repo="$1" prompt="$2"
  [[ -z "$prompt" ]] && prompt="(no prompt provided)"

  local summary=""
  if _saver_have_claude; then
    local to
    if to="$(_saver_have_timeout)"; then
      summary="$("$to" 10 claude --print \
        "Summarize the following user request as a git commit message subject (50 chars, imperative voice, no trailing period). Output only the subject line, no quotes, no explanation: $prompt" \
        2>/dev/null || true)"
    else
      # No timeout binary on PATH — call claude bare and accept the latency
      # risk. The fallback below still triggers if claude errors out.
      summary="$(claude --print \
        "Summarize the following user request as a git commit message subject (50 chars, imperative voice, no trailing period). Output only the subject line, no quotes, no explanation: $prompt" \
        2>/dev/null || true)"
    fi
  fi

  # Strip whitespace; take first non-empty line.
  summary="$(printf '%s\n' "$summary" | awk 'NF { print; exit }')"
  summary="${summary#"${summary%%[![:space:]]*}"}"
  summary="${summary%"${summary##*[![:space:]]}"}"

  if [[ -z "$summary" ]]; then
    # Heuristic fallback: "Update: <first 60 chars of prompt>", trailing period
    # stripped to match the stylistic ask.
    local snippet="${prompt:0:60}"
    snippet="${snippet%.}"
    summary="Update: $snippet"
  fi

  printf '%s\n' "$summary"
}

# saver_summarize_pr <repo-path> <diff-or-context>
# Multi-line PR body (or title; caller chooses how to use it). Same shape as
# saver_summarize_turn but doesn't collapse to a single line.
saver_summarize_pr() {
  local repo="$1" ctx="$2"
  [[ -z "$ctx" ]] && ctx="(no context provided)"

  local summary=""
  if _saver_have_claude; then
    local to
    if to="$(_saver_have_timeout)"; then
      summary="$("$to" 10 claude --print \
        "Summarize the following diff/context as a GitHub PR body (1-3 short paragraphs, plain Markdown, no code fences, no headings): $ctx" \
        2>/dev/null || true)"
    else
      summary="$(claude --print \
        "Summarize the following diff/context as a GitHub PR body (1-3 short paragraphs, plain Markdown, no code fences, no headings): $ctx" \
        2>/dev/null || true)"
    fi
  fi

  # Trim outer whitespace; preserve internal newlines.
  summary="$(printf '%s' "$summary" | awk '
    BEGIN { started = 0 }
    {
      if (!started && NF == 0) next
      started = 1
      lines[++n] = $0
    }
    END {
      # Drop trailing empty lines
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ')"

  if [[ -z "$summary" ]]; then
    summary="Summary unavailable. See commit history for details."
  fi

  printf '%s\n' "$summary"
}

# ============================================================================
# Save flow (ARD-0022 §7)
# ============================================================================

# _saver_short_sha <repo-path>
# 8-char short SHA of HEAD. Used in the saved-branch suffix.
_saver_short_sha() {
  git -C "$1" rev-parse --short=8 HEAD
}

# _saver_slugify <text> <max-len>
# Derives a kebab-case slug from arbitrary text. Lowercased, non-alnum →
# dashes, runs of dashes collapsed, trimmed to max-len, leading/trailing
# dashes stripped.
_saver_slugify() {
  local text="$1" max="${2:-30}"
  local s
  s="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')"
  s="${s#-}"; s="${s%-}"
  printf '%s' "${s:0:$max}"
}

# saver_save <repo-path> <profile-json> [--message <text>] [--draft|--ready] [--target <branch>]
# The full save flow per ARD-0022 §7. Pushes the current branch as a named
# saved branch and opens a PR via gh. Prints the PR URL on success. Leaves
# the WIP branch intact on any failure (the marketer's work is safe).
saver_save() {
  local repo="$1"; shift
  local profile_json="$1"; shift

  [[ -z "$repo" ]] && die "saver_save: missing <repo-path>"
  [[ -z "$profile_json" ]] && die "saver_save: missing <profile-json>"
  [[ -d "$repo/.git" ]] || die "saver_save: not a git repo: $repo"
  require_cmd git
  require_cmd jq

  # Flag parse (parameters only for what's used; no future-flex knobs).
  local message_override="" draft_override="" target_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message) [[ $# -ge 2 ]] || die "saver_save: --message requires a value"
                 message_override="$2"; shift 2 ;;
      --draft)   draft_override="true"; shift ;;
      --ready)   draft_override="false"; shift ;;
      --target)  [[ $# -ge 2 ]] || die "saver_save: --target requires a value"
                 target_override="$2"; shift 2 ;;
      *) die "saver_save: unknown flag $1" ;;
    esac
  done

  # Read save: defaults from the normalized profile JSON.
  local target_branch reviewers_from reviewers draft branch_prefix pr_template
  target_branch="$(jq -r '.save.target_branch // "main"' <<<"$profile_json")"
  reviewers_from="$(jq -r '.save.reviewers_from // empty' <<<"$profile_json")"
  reviewers="$(jq -r '(.save.reviewers // []) | join(",")' <<<"$profile_json")"
  draft="$(jq -r '.save.draft_by_default // true' <<<"$profile_json")"
  branch_prefix="$(jq -r '.save.branch_prefix // "marketer/"' <<<"$profile_json")"
  pr_template="$(jq -r '.save.pr_template // empty' <<<"$profile_json")"

  [[ -n "$target_override" ]] && target_branch="$target_override"
  [[ -n "$draft_override" ]] && draft="$draft_override"
  # Default reviewer source if neither is configured (per ARD-0022 §7.1
  # documented default: codeowners).
  if [[ -z "$reviewers_from" && -z "$reviewers" ]]; then
    reviewers_from="codeowners"
  fi

  # Current branch is the WIP branch the marketer's session built up.
  local current_branch
  current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  if [[ "$current_branch" == "$target_branch" ]]; then
    die "saver_save: on target branch ($target_branch); refusing to save (start a WIP branch first via 'boring wip start')"
  fi

  # Slug for the saved branch. v0: AI-summarized title (or override) → slug.
  local title summary_ctx diff_summary
  diff_summary="$(git -C "$repo" log --format='%s' "${target_branch}..HEAD" 2>/dev/null | head -n 20 || true)"
  if [[ -n "$message_override" ]]; then
    title="$message_override"
  else
    summary_ctx="Commit subjects on this branch:\n$diff_summary"
    title="$(saver_summarize_turn "$repo" "$summary_ctx")"
  fi

  local slug short_sha date_part saved_branch
  slug="$(_saver_slugify "$title" 30)"
  [[ -z "$slug" ]] && slug="save"
  short_sha="$(_saver_short_sha "$repo")"
  date_part="$(date +%Y-%m-%d)"
  saved_branch="${branch_prefix}${slug}-${date_part}-${short_sha}"

  # Body: AI-summarized + file list footer (cheap to compute, useful for review).
  local file_list body
  file_list="$(git -C "$repo" diff --name-only "${target_branch}..HEAD" 2>/dev/null || true)"
  body="$(saver_summarize_pr "$repo" "Diff between $target_branch and HEAD on $current_branch:\n${diff_summary}\n\nFiles changed:\n${file_list}")"
  body="${body}

---
Files changed:
$(printf '%s\n' "$file_list" | sed 's/^/- /')

Generated from a boring-ui session (ARD-0022)."

  # Reviewer list: explicit list wins; codeowners is gh's responsibility
  # (gh pr create has no --reviewer-from-codeowners flag, but reviewers can be
  # left empty and CODEOWNERS auto-requests on PR open if the repo is configured).
  local -a gh_args
  gh_args=(pr create --base "$target_branch" --head "$saved_branch" \
           --title "$title" --body "$body")
  if [[ "$draft" == "true" ]]; then
    gh_args+=(--draft)
  fi
  if [[ -n "$reviewers" ]]; then
    gh_args+=(--reviewer "$reviewers")
  fi
  if [[ -n "$pr_template" && -f "$repo/$pr_template" ]]; then
    # gh has no --template flag for pr create; the convention is to merge the
    # template into the body. Keep the AI summary above the template.
    body="${body}

---
$(cat "$repo/$pr_template")"
    # Rebuild the args with the merged body (gh args carry the body value).
    gh_args=(pr create --base "$target_branch" --head "$saved_branch" \
             --title "$title" --body "$body")
    if [[ "$draft" == "true" ]]; then
      gh_args+=(--draft)
    fi
    if [[ -n "$reviewers" ]]; then
      gh_args+=(--reviewer "$reviewers")
    fi
  fi

  # Branch the saved name from current HEAD, push, open PR. If anything below
  # fails, we leave the WIP branch alone — the marketer's work is safe.
  if ! command -v gh >/dev/null 2>&1; then
    log_error "saver_save: 'gh' CLI not installed. WIP branch $current_branch left intact."
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log_error "saver_save: 'gh' not authenticated. Run 'gh auth login'. WIP branch $current_branch left intact."
    return 1
  fi

  log_step "saver: creating saved branch $saved_branch from $current_branch"
  if ! git -C "$repo" branch "$saved_branch" "$current_branch" >/dev/null 2>&1; then
    log_error "saver_save: failed to create saved branch $saved_branch (already exists?). WIP branch $current_branch left intact."
    return 1
  fi

  log_step "saver: pushing $saved_branch"
  if ! git -C "$repo" push -u origin "$saved_branch" >/dev/null 2>&1; then
    log_error "saver_save: push failed for $saved_branch. WIP branch $current_branch left intact."
    git -C "$repo" branch -D "$saved_branch" >/dev/null 2>&1 || true
    return 1
  fi

  log_step "saver: opening PR via gh"
  local pr_url
  if ! pr_url="$(cd "$repo" && gh "${gh_args[@]}" 2>&1)"; then
    log_error "saver_save: gh pr create failed: $pr_url"
    log_error "  WIP branch $current_branch left intact; saved branch $saved_branch is on remote."
    return 1
  fi

  log_success "saver: PR opened"
  printf '%s\n' "$pr_url"
}
