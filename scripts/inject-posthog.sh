#!/usr/bin/env bash
#
# scripts/inject-posthog.sh — inject the PostHog snippet into a built HTML file.
#
# Used by the GitHub Pages workflow after `mkdocs build` to instrument
# docs/index.html (the marketing landing page, which MkDocs copies through
# verbatim — no Jinja templating). The MkDocs-generated pages are already
# instrumented via overrides/main.html, so this script only touches the
# landing page.
#
# Usage:
#   POSTHOG_KEY=phc_xxx scripts/inject-posthog.sh site/index.html
#
# No-op when POSTHOG_KEY is unset or empty — the build stays clean locally
# and in CI runs that don't have the secret configured.

set -euo pipefail

target="${1:?usage: scripts/inject-posthog.sh <html-file>}"
[[ -f "$target" ]] || { echo "inject-posthog: $target does not exist" >&2; exit 1; }

if [[ -z "${POSTHOG_KEY:-}" ]]; then
  echo "inject-posthog: POSTHOG_KEY not set; skipping injection into $target"
  exit 0
fi

host="${POSTHOG_HOST:-https://us.i.posthog.com}"

# Skip if already injected (idempotency for local-run rebuilds).
if grep -q "posthog.init" "$target"; then
  echo "inject-posthog: $target already contains posthog.init; skipping"
  exit 0
fi

# Build the snippet in a temp file. Heredoc with the literal stub script,
# then a tiny tail that calls posthog.init with the env-var values. Keeps
# the giant minified blob exactly as PostHog ships it.
snippet="$(mktemp)"
trap 'rm -f "$snippet"' EXIT

cat > "$snippet" <<HTMLEOF
  <script>
    !function(t,e){var o,n,p,r;e.__SV||(window.posthog && window.posthog.__loaded)||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="Mi Ri init Vi Gi Rr Wi Ji Bi capture calculateEventProperties tn register register_once register_for_session unregister unregister_for_session an getFeatureFlag getFeatureFlagPayload getFeatureFlagResult isFeatureEnabled reloadFeatureFlags updateFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSurveysLoaded onSessionId getSurveys getActiveMatchingSurveys renderSurvey displaySurvey cancelPendingSurvey canRenderSurvey canRenderSurveyAsync un identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset setIdentity clearIdentity get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException addExceptionStep captureLog startExceptionAutocapture stopExceptionAutocapture loadToolbar get_property getSessionProperty nn Xi createPersonProfile setInternalOrTestUser sn Hi cn opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing get_explicit_consent_status is_capturing clear_opt_in_out_capturing Ki debug Lr rn getPageViewId captureTraceFeedback captureTraceMetric Di".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);
    posthog.init('${POSTHOG_KEY}', {
        api_host: '${host}',
        defaults: '2026-01-30',
        person_profiles: 'identified_only',
    })
  </script>
HTMLEOF

# Insert the snippet immediately before </head>. Use awk (POSIX) rather
# than sed -i (BSD/GNU sed differ on the -i argument); also avoids the
# multi-line-with-special-chars escaping nightmare a sed replacement
# would entail.
awk -v snippet_file="$snippet" '
  /<\/head>/ && !injected {
    while ((getline line < snippet_file) > 0) print line
    close(snippet_file)
    injected = 1
  }
  { print }
' "$target" > "$target.tmp"
mv "$target.tmp" "$target"

echo "inject-posthog: snippet injected into $target (host=$host)"
