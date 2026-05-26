# ARD-0032: `boring secret` — local credential provisioning into the OS keyring

- **Status:** Accepted
- **Date:** 2026-05-26
- **Type:** Mini-ARD
- **Related:** [[ard-0002-dbx-as-runtime-dependency]] (amends the resolve-only stance), [[ard-0004-shopify-first]], [[ard-0005-security-model-inversion]], [[ard-0021-boring-ui-host-proxy-and-project-picker]], [[ard-0030-dev-profile-field-foreground-command-on-boring-open]]

## Decision

Add a `boring secret {set|get|rm} <service>/<account>` command that provisions a secret into the **host OS keyring** (macOS Keychain via `security`; Linux libsecret via `secret-tool`) — the *same* backend the existing `secret://keychain:<service>/<account>` resolver reads. `set` reads the value from **stdin** so it never enters argv or shell history. Logic lives in `lib/secrets.sh` alongside `secret_resolve` (`secret_set`/`secret_get`/`secret_rm`); the CLI surface is `cmd_secret` in the main `boring` script.

This enables the **local, provisioned-once credential-broker** model: an engineer (or IT) runs `boring secret set` once per machine at onboarding to stash a credential (e.g. a Shopify Theme Access token); thereafter `boring open` resolves it from the keyring and injects it via the existing `--remote-env` path (no disk write). A non-engineer then runs `boring open` — or clicks the project in the boring-ui picker, which calls the same `cmd_open` — and the container is pre-authenticated with **zero per-use auth**: no OAuth, no vault sign-in, no `.env`, no Shopify admin.

## Rationale

The Shopify preset's reason for existing is non-engineers running one command for a live theme preview, but `shopify theme dev` requires auth. Every prior path failed the zero-marketer-setup bar: in-container browser OAuth re-prompts every session (and the session lands on the container's ephemeral FS); host-CLI bind-mounts surface `root:root` to the non-root `dev` user and don't persist; a team vault (`op://`) requires each marketer to install a vault CLI and sign in. Provisioning the credential **once into the local OS keyring** removes all per-use marketer steps while reusing machinery boring already has (the `keychain:` resolver + `--remote-env` injection in `cmd_open`). No new daemon, no network service, no boring-owned store.

### Relationship to ARD-0002 (the load-bearing point)

ARD-0002 establishes boring as a **resolve-only** secret consumer that "owns zero secret storage … never a new keyring/file that boring writes to itself." `boring secret set` makes boring *write* a secret, which this ARD deliberately permits **within ARD-0002's intent**: boring writes into the **OS's existing keyring**, not a boring-owned store, and only into the exact backend the `keychain:` scheme already resolves from. boring still owns no storage; it adds an ergonomic provision/read/delete layer over a backend it already reads. This is a bounded extension (resolve-only → resolve + provision, same OS backends), not a new storage subsystem. Networked stores (1Password, Vault, AWS SM) keep their own native provisioning — `boring secret` is intentionally keyring-only.

## Consequences

- **Positive:** non-engineers get a true one-command, pre-authenticated launch; the credential never touches argv, shell history, the repo, or compose YAML on disk; works identically for CLI `boring open` and proxy/boring-ui-launched opens; rotation is a re-run of `boring secret set` (`-U` on macOS updates in place).
- **Negative / bounded:** the credential is per-machine, so each machine needs the one-time provisioning step (acceptable for the onboarding model; a central/network broker was explicitly deferred). `boring secret list` is omitted — enumerating generic-password items is awkward and inconsistent across `security` and `secret-tool`, and `get`/`rm` cover the operational need.
- **Neutral:** keyring-only by design; if a team prefers a shared/networked store, the existing `op://`/`vault://`/`aws-sm:` schemes already cover that and are unchanged.
