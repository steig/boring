# ARD-0003: boring shells out to the devcontainer CLI for container lifecycle

- **Status:** Accepted
- **Date:** 2026-05-23
- **Type:** Mini-ARD
- **Related:** [[ard-0001-v1-architecture]], [[ard-0002-dbx-as-runtime-dependency]], [[convention-ards]]

## Decision

boring delegates container lifecycle (build, up, exec, down) to the official **`@devcontainers/cli`** (executable `devcontainer`, installable with `npm i -g @devcontainers/cli`). boring generates `devcontainer.json` and `docker-compose.yml` from `.boring/profile.yaml` and invokes `devcontainer up` / `devcontainer exec` / `docker compose down` rather than re-implementing the lifecycle in shell over the Docker API.

## Rationale

Same principle as [ARD-0002](ard-0002-dbx-as-runtime-dependency.md): the devcontainer CLI is a maintained, official tool that already does exactly this. Reimplementing it would duplicate code Microsoft maintains, and any divergence from the spec causes subtle "works in VS Code, doesn't work in boring" bugs. Using `devcontainer up` also gives VS Code / Cursor / JetBrains IDE attach for free, because the same `devcontainer.json` boring generates is what their IDE reads.

## Consequences

- boring's runtime dependencies become: a container runtime (Orbstack/Docker), `dbx`, `devcontainer`. All have first-class installers and obvious upgrade paths; all are checked by `boring doctor`.
- `install.sh` checks for `devcontainer` on PATH and tells the user how to install if missing (does not auto-install via npm, since npm itself may not be present — pointing to clear instructions is safer than guessing).
- boring's own code shrinks: no `docker compose up/down` wrapping in the runtime path, no devcontainer JSON parsing (only generation).
