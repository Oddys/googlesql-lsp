---
name: issues
description: Analyses a file, directory, module, or the whole project to surface potential issues — bugs and uncovered edge cases, security risks, performance concerns, and non-idiomatic style. Also flags code/documentation mismatches and out-of-date language or library versions. Use when the user says "find issues in X", "review X for problems", "what could go wrong in X", "audit X", or asks what could be improved.
---

# Issues

Find real, actionable problems in a given target — a single file, a
directory, a module, or the project as a whole — and report them ranked by
severity. This is a *diagnostic* skill: it reads and reasons, it does not
change code on its own. Every finding must trace to a concrete line and come
with a concrete failure or improvement, not a vague worry.

Do not confuse this with `code-review` (which reviews the working diff) — this
skill audits code that already exists, whether or not it was just changed.

## Before analysing

1. Resolve the target precisely. If the user named a file or symbol, that's
   the scope. If they named a directory/module, that's the scope. If they said
   "the project" or gave nothing, treat the whole `src/` tree as scope but say
   so, and offer to narrow it. If ambiguous, ask before spending effort.
2. Read the target in full — every file in scope, top to bottom. Do not audit
   from a partial read, a grep sample, or memory of similar code. For a
   directory/project, read the entry points and the core modules fully, and at
   least skim every file so nothing in scope is unexamined.
3. Trace the non-obvious dependencies. When code in scope calls a
   project-specific function, relies on an invariant established elsewhere, or
   trusts an input from another layer, read enough of that other code to judge
   whether the assumption actually holds. A bug is often the gap between what
   one function guarantees and what its caller assumes.
4. Note the language and its edition/version, plus the declared dependency
   versions - `Cargo.toml` / `Cargo.lock` for Rust, 
   `pyproject.toml` / `uv.lock` for Python, `build.zig` / `build.zig.zon` for Zig, 
   or the equivalent manifest+lockfile for whatever language the target is in). 
   You'll use these both to judge idiom and for the version check at the end.

## What to look for — in priority order

Search in this order and present findings in this order. A confirmed bug
outranks any number of style nits.

1. **Bugs & uncovered edge cases** — the highest-value findings. Look for:
   - Inputs the code doesn't handle: empty/`None`/zero-length, boundary values,
     Unicode vs. byte offsets, very large inputs, negative numbers, overflow.
   - Error paths: `unwrap()`/`expect()`/`panic!` on fallible operations,
     swallowed errors, `?` that discards context, results ignored.
   - Concurrency: shared mutable state, races, lock ordering, `await` points
     that hold a lock, cancellation, tasks that can deadlock or leak.
   - Logic errors: off-by-one, inverted conditions, wrong operator, fallthrough
     cases, state left inconsistent on early return.
   - Resource handling: leaks, unclosed handles, unbounded growth, missing
     cleanup on the error path.
   For each, describe the *specific* input or interleaving that triggers it and
   what goes wrong — a bug you can't demonstrate is a hypothesis, so label it as
   one if you can't pin the trigger.

2. **Security risks** — untrusted input reaching a dangerous sink. Command/SQL
   injection, path traversal, unvalidated deserialization, secrets in logs or
   source, unsafe subprocess invocation, TOCTOU, missing authz/limits on anything
   externally reachable. Name the source→sink path, not just "this looks
   unsafe."

3. **Performance & behaviour under load** — what degrades as input or
   concurrency grows. Accidental O(n²), repeated work that could be cached,
   allocations in hot paths, blocking calls on an async runtime, unbounded
   queues/maps, per-request work that could be amortised, missing back-pressure.
   Prefer concrete reasoning ("this rebuilds the regex on every keystroke")
   over generic advice.

4. **Style & idiom** — more idiomatic ways to express the same thing in this
   language, and consistency with the surrounding code. Iterator chains vs.
   manual loops, `if let`/`match` ergonomics, error-handling idioms, naming,
   dead code, needless clones. Keep these last and keep them brief; do not let
   style noise bury a real bug.

## Documentation alignment

While reading, check the code against every claim made about it: inline
comments, doc comments/docstrings, `README.md`, and any project docs
(`EXPLAINED.md`, `DIAGRAMS.md`, design notes). When code and documentation
disagree — a comment describing behaviour the code no longer has, a README flag
that doesn't exist, a docstring with the wrong return contract — **report the
mismatch and ask the user which side is wrong**: should the code change to match
the docs, or the docs change to match the code? Do not silently "fix" either;
the mismatch itself is the finding, and only the user knows which was intended.
Use `AskUserQuestion` when there are a few discrete mismatches to resolve.

## Version currency

After the analysis, check whether the language edition/version and the
dependency versions in scope are the latest:

1. From the manifest/lockfile, list what's in use and its version.
2. If anything is behind, tell the user, and **ask whether they want you to
   look up the latest versions for possible improvements** — do not go fetch
   release notes for a dozen crates uninvited. Use `AskUserQuestion` /
   `ExitPlanMode`-free confirmation.
3. If they agree, let the user choose *which* libraries and *which* target
   versions to investigate (present the outdated ones as options rather than
   assuming "all, latest"). Only then use `WebSearch`/`WebFetch` to find, for
   the chosen library at the chosen version, concretely relevant changes:
   security fixes, bug fixes, API improvements, or performance wins that touch
   how this project uses it. Skip changelog entries irrelevant to the code in
   scope.
4. Report what an upgrade would buy (and cost — breaking changes, migration
   effort) so the user can decide. Do not perform the upgrade unless asked.

## Reporting

- Lead with a one-line summary of scope and the count of findings by severity.
- Group findings under the four headings above, most severe first within each.
- For each finding: a `file_path:line_number` anchor, one sentence stating the
  defect, then the concrete trigger/consequence, then a suggested fix. Be
  specific enough that the user could act without re-deriving the problem.
- Separate confirmed problems from suspicions — don't inflate a "might be" into
  a "will break." Say which you verified and which you're flagging on suspicion.
- If a scope is clean in a category, say so briefly rather than padding.
- Keep it proportional: a 40-line helper gets a short list; a module gets
  structure. Don't invent findings to fill a section.
- This skill reports; it does not edit. After presenting, offer to fix specific
  findings if the user wants — but make that a separate, explicit step.
