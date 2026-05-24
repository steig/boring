# Security Policy

boring is a security-adjacent tool — it sits between non-engineers, AI agents,
and production-shaped data. We take vulnerability reports seriously and aim
to acknowledge within a few business days.

## Reporting

Email [tom@steig.io](mailto:tom@steig.io) with a description, reproduction
steps, and (if you have them) suggested mitigations. Please do not file
public GitHub issues for security bugs.

We don't have a bug bounty program. We'll credit reporters by name (or alias)
in the relevant ARD or CHANGELOG entry unless you'd rather stay anonymous.

## Disclosure timeline

We target a 90-day coordinated-disclosure window. If a fix takes longer we'll
say so and propose a revised date.

## In scope

- Container-escape paths via the `install-egress` entrypoint or other parts of
  the egress-enforcement chain.
- Audit-log tampering paths that bypass the FIFO + host-collector model
  ([ARD-0010](docs/ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md)).
- Secret-resolver leak channels — anything that causes a resolved `secret://`
  URI value to land on disk, in a log, in an env file, in `docker inspect`
  output, or any other persisted artifact.
- Profile parser injection bugs (YAML or jq) that let a hostile
  `.boring/profile.yaml` execute host-side code outside the documented schema.
- Bypasses of trust-anchor enforcement that let an in-container agent modify
  `.boring/*`, `~/.claude/settings.json`, or the audit-hook scripts
  ([ARD-0006](docs/ards/ard-0006-profile-is-the-trust-anchor.md)).

## Out of scope

- **Host-side modification of `.boring/*`.** The threat model
  ([ARD-0005](docs/ards/ard-0005-security-model-inversion.md)) is keeping
  non-engineers and AI from accidentally damaging prod systems, not
  preventing a user with shell access on the host. Host edits are
  authorized by design.
- Vulnerabilities in upstream dependencies (`docker`, `@devcontainers/cli`,
  `dbx`, `yq`, `jq`, `op`, `vault`, etc.) — please report those upstream.
