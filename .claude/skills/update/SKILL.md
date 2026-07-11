---
name: update
description: Checks whether the language edition/version and the declared dependency versions in a target are the latest, and suggests bump-ups worth taking. For each outdated library, looks up what a chosen upgrade would buy (security fixes, bug fixes, API/perf improvements) and what it would cost (breaking changes, migration effort). Use when the user says "check for updates", "are my dependencies up to date", "what can I bump", "suggest version upgrades", or asks whether a library/language version is current.
---

# Update

Check whether the language edition/version and the dependency versions in a
target — a file, a directory, or the whole project — are current, and tell the
user which upgrades are worth taking and why. This is an *advisory* skill: it
reads manifests, looks up releases, and reports. It does **not** edit manifests
or perform upgrades unless the user explicitly asks in a follow-up step.

For finding bugs, security holes, performance problems, or non-idiomatic code
in the target itself, use the `issues` skill instead — this skill is only about
version currency.

## Before checking

1. Resolve the target precisely. If the user named a file/module, scope the
   dependency check to what that code actually uses. If they said "the project"
   or gave nothing, treat the whole project's manifest+lockfile as scope, but
   say so.
2. Before starting a new check, read `UPDATE.md` (if it exists) to see what was
   previously reported. Use it to spot what's changed since — a dependency that
   was flagged and has now been bumped, or one that's fallen further behind.
3. Identify the manifest and lockfile for the language and read them fully —
   `Cargo.toml` / `Cargo.lock` for Rust, `pyproject.toml` / `uv.lock` for
   Python, `package.json` / `package-lock.json` for Node, `build.zig` /
   `build.zig.zon` for Zig, or the equivalent for whatever language the target
   is in. Note the declared language edition/version too.
3. If the target is narrower than the whole project, note which of the declared
   dependencies the in-scope code actually imports/uses, so you can prioritise
   the ones that matter and skip the rest.

## Checking currency

1. From the manifest/lockfile, list what's in use and its pinned version,
   including the language edition/version.
2. Determine the latest available version for each. Use `WebSearch`/`WebFetch`
   (or the language's registry/CLI when available) to find current releases.
   Don't guess from memory — versions move.
3. Build the list of what's behind: current version → latest version, and how
   far behind (patch / minor / major).

## What to look up and suggest

Don't fetch release notes for a dozen libraries uninvited, and don't assume
"all, latest." Instead:

1. Present the outdated items as options and let the user choose *which*
   libraries and *which* target versions to investigate. Use `AskUserQuestion`
   when there are a handful of discrete choices.
2. Only then, for each chosen library at the chosen target version, look up the
   concretely relevant changes between the current and target version:
   - **Security fixes** — CVEs or advisories that affect how this project uses
     the library.
   - **Bug fixes** — fixes to behaviour the project actually relies on.
   - **API improvements** — cleaner or safer APIs replacing what's used now.
   - **Performance wins** — improvements that touch the project's hot paths.
   Skip changelog entries irrelevant to the code in scope.
3. Flag the cost, not just the benefit: breaking changes, required migration
   steps, minimum-language-version bumps, transitive-dependency churn.

## Reporting

- Lead with a one-line summary: how many dependencies are current, how many are
  behind, and whether any are behind by a major version or carry a security
  fix.
- Give a compact table or list of `name: current → latest (patch/minor/major)`,
  most-urgent first — security-relevant and major-version-behind at the top.
- For each upgrade the user asked to investigate, report what it would buy and
  what it would cost, concretely enough to decide. Separate "clearly worth it"
  from "optional" from "risky / defer."
- If everything is current, say so plainly instead of padding.
- This skill advises; it does not edit manifests or run upgrade commands. After
  reporting, offer to perform specific bumps as a separate, explicit step if the
  user wants them.

## Saving findings

- Once you've presented the currency check, ask the user whether they want you
  to save it to `UPDATE.md`, or whether they have follow-up questions. Keep
  asking after each answer until the user tells you to either save or discard.
- When saving, append under a dated heading rather than overwriting, so
  `UPDATE.md` accumulates a history of currency checks. Keep the
  `current → latest (patch/minor/major)` list and the buy/cost notes for each
  investigated upgrade. When a previously flagged dependency has since been
  upgraded, mark it done rather than silently dropping it.
