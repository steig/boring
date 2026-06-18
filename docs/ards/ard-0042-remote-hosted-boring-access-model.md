# ARD-0042: Remote / hosted boring access model — trusted-share now, team-hosted next, public SaaS parked

- **Status:** Accepted (phased)
- **Date:** 2026-06-18
- **Deciders:** Tom (Claude facilitating, via `/grill-me`)
- **Prompted by:** "can I run boring on a server and expose the web URL to someone to use?"
- **Amends:** [ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) (proxy was localhost/`boring.local` + a single shared token → public TLS + per-user identity for team-hosting), [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) (single-user lock → real multi-user concurrency), [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) (operator-resolved secrets — inverted only under the parked public-SaaS phase), [ARD-0005](ard-0005-security-model-inversion.md)/[ARD-0006](ard-0006-profile-is-the-trust-anchor.md) (the trust model assumed the operator *is* the user).
- **Related:** [[ard-0041-multi-agent-cockpit-on-web-substrate]] (the cockpit is the hosted UI), [[ard-0011-egress-enforcement-via-iptables]], [[ard-0014]] via #14 (egress internal-network blocks).

## Context

Today boring-ui is built **local, single-user, operator-trusted**: the backend has *no* auth ("trusts the socket boundary as the auth boundary … no token check inside the container"); `boring-proxy` gates with a *single shared* 256-bit token + cookie bound to `boring.local` via mkcert; and secret URIs resolve **as the host operator** into the container (ARD-0002). Exposing this to others crosses several baked-in assumptions, and the two asks diverge on the axis that matters — **whose secrets the agent uses**:

- **(a) trusted-share:** let one trusted person into *my* running boring → they act **as me, with my resolved secrets.**
- **(b) hosted product:** users act **as themselves, with isolated secrets the host cannot see** — the *opposite* secret model. So (a) does not incrementally become (b).

And (b) forks:
- **(b1) team-hosted:** one org runs boring on its infra for its (trusted) members; secrets are the org's; isolation means "don't clobber each other." Composes with the mixed-teams thesis and with (a).
- **(b2) public multi-tenant SaaS:** arbitrary untrusted tenants, each with secrets boring-the-host cannot see, plus quotas/abuse/billing. Inverts ARD-0002 and is a company-scale re-architecture.

## Decision

A phased model, gated on a hard security prerequisite.

**Hard prerequisite for *any* remote exposure:** complete the egress internal-network blocks deferred from #14 (the ARD-0036 `cross_sandbox` / RFC1918 categories). Until they ship, a remote user's in-container agent can reach the **host's LAN**; only the metadata/link-local floor is enforced today.

**Phase 1 — (a) trusted-share (near-term).** Expose `boring-proxy` (its existing token + cookie) behind **real public TLS** (not mkcert) via a reverse proxy/tunnel, with a loud, unavoidable warning that the invited person **acts as the operator, with the operator's resolved secrets**, inside the sandbox. Single-user lock stands. This is the "demo my project to a teammate/customer who can't install anything" case and directly advances the mixed-teams thesis (a non-engineer teammate just gets a URL).

**Phase 2 — (b1) team-hosted ("hosted boring," the target).** The product direction. Requires:
- **Per-user identity** — replace the single shared token with per-user authentication.
- **Multi-user concurrency** — turn ARD-0022's single-user lock into real concurrent access (the [ARD-0041](ard-0041-multi-agent-cockpit-on-web-substrate.md) multi-agent cockpit already pushes the UI toward this).
- **Org-scoped secrets** — operator-trust remains acceptable *within a trusted org*; secrets are the org's, not per-stranger.
- Per-project/per-user sandbox isolation (boring already containerizes; the proxy, secrets, and audit are operator-scoped and must become org/user-aware).

**(b2) public multi-tenant SaaS — parked.** Explicitly out of scope here. It inverts ARD-0002 (every tenant brings isolated secrets the host cannot read), and adds quotas, abuse handling, and billing — a separate strategic bet with its own future ARD and timeline.

## Consequences

### Positive
- (a) is mostly already there (token exists); a small, high-value step that validates demand and serves non-engineers without installs.
- (a) + (b1) + the cockpit (ARD-0041) compose into one coherent product: a hosted "mission control" where a team's engineers and non-engineers each get a URL into shared/per-project boring sandboxes.

### Negative / accepted
- (b1) is real security-architecture work (identity, concurrency, isolation), not a flag.
- The egress-internal-blocks prerequisite means remote exposure is *blocked* until that lands — accepted, because shipping it earlier would expose the host LAN.

## Alternatives Considered (rejected)
- **`ngrok` the proxy and call it done.** Rejected: mkcert TLS won't validate remotely, and without the egress internal blocks the agent reaches the host LAN; the "acts as you" exposure must be explicit, not accidental.
- **Treat (a) as a stepping stone to (b2).** Rejected: they have opposite secret models — (a)'s "acts as the operator" is exactly what (b2) must prevent.
- **Jump straight to (b2) public SaaS.** Rejected as premature: company-scale, inverts the secret model, and unvalidated; (b1) team-hosting is the tractable target that composes with everything already built.
