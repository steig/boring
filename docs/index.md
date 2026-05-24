---
title: boring documentation
description: Profile-driven dev containers for any stack — turn any repo into a one-command, isolated dev environment your whole team can think inside.
---

# boring

> Turn any repo into a one-command, isolated dev environment where mixed teams &mdash; engineers, marketers, managers &mdash; use code as a thinking medium. Wireframes, mockups, prototypes, pitches, with Claude as the collaborator at the keyboard.

These are the **docs**. If you're here for the pitch &mdash; what boring is, why it exists, who it's for &mdash; head to [**Why boring**](why/).

---

## Where to start

<div class="grid cards" markdown>

-   :material-rocket-launch: **[Getting Started](getting-started.md)**

    Install boring, drop a profile into your repo, open the container.
    The five-minute path from clone to working dev loop.

-   :material-file-document-edit: **[Anatomy of a Profile](profile-reference.md)**

    Every field in `.boring/profile.yaml` with examples. The schema reference.

-   :material-folder-multiple: **[Examples](https://github.com/steig/boring/tree/main/examples)**

    Three sample profiles to copy-modify: minimal (Shopify), Django + Postgres,
    Node + Redis.

-   :material-book-open-variant: **[Architecture Decision Records](ards/)**

    Every material design decision is recorded as an ARD at the time of the
    decision. Read these to understand the *why*.

-   :material-history: **[Changelog](changelog.md)**

    What shipped, when, and what it changed.

-   :material-shield-lock: **[Security](https://github.com/steig/boring/blob/main/SECURITY.md)**

    Responsible disclosure path + the security model summary.

</div>

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/boring/main/install.sh | bash
boring doctor
```

The installer clones the repo to `~/.local/share/boring/` and symlinks `boring` into `~/.local/bin/`. Full requirements + dep table in [Getting Started](getting-started.md).

---

## Status

**v0.6.0-dev.** Code surface covers [ARD-0008](ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s v0.3 through v0.6 slices end-to-end. v1.0 polish (brew formula, marketing final pass, broader real-world dogfood) is the gap to a tagged release.

This is a one-maintainer project in active dogfood, currently validated against two production repos (a Shopify theme and a Django + React + Postgres app), both private. The thesis &mdash; "mixed teams use code as a thinking medium with Claude as the collaborator" &mdash; is **not yet validated by external users**. If you try it and find a sharp edge, [open an issue](https://github.com/steig/boring/issues) or email [tom@steig.io](mailto:tom@steig.io).
