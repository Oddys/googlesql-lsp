---
name: issues
description: Analyses a file, directory, module, or the whole project to surface potential issues — bugs and uncovered edge cases, security risks, performance concerns, and non-idiomatic style. Also flags code/documentation mismatches. Use when the user says "find issues in X", "review X for problems", "what could go wrong in X", "audit X", or asks what could be improved. For checking whether dependency/language versions are current, use the `updates` skill instead.
---

# Issues

Find real, actionable problems in a given target — a single file, a
directory, a module, or the project as a whole — and report them ranked by
severity. This is a *diagnostic* skill: it reads and reasons, it does not
change code on its own. Every finding must trace to a concrete line and come
with a concrete failure or improvement, not a vague worry.

Do not confuse this with `code-review` (which reviews the working diff) — this
skill audits code that already exists, whether or not it was just changed. For
checking whether dependency/language versions are current, use the `updates`
skill instead.

This skill's saved output lives under `dig/` — the shared home for the artifacts
of the `draw`, `explain`, `issues`, and `updates` skills (`dig/DIAGRAMS.md` +
`dig/diagrams/*.html`, `dig/EXPLAINED.md`, `dig/ISSUES.md`, `dig/UPDATE.md`
respectively).

## Before analysing

1. Resolve the target precisely. If the user named a file or symbol, that's
   the scope. If they named a directory/module, that's the scope. If they said
   "the project" or gave nothing, treat the whole `src/` tree as scope but say
   so, and offer to narrow it. If ambiguous, ask before spending effort.
2. Before starting a new analysis, read `dig/ISSUES.md` (if it exists) to see
   what has already been reported. If a finding is already recorded there, don't
   re-report it as new — note it's known, and focus on what's changed or
   uncovered since.
3. Read the target in full — every file in scope, top to bottom. Do not audit
   from a partial read, a grep sample, or memory of similar code. For a
   directory/project, read the entry points and the core modules fully, and at
   least skim every file so nothing in scope is unexamined.
4. If the file contains any comments that start with `:i` (e.g. `//:i` or `#:i`)
   make sure you check those user's concerns.
5. Trace the non-obvious dependencies. When code in scope calls a
   project-specific function, relies on an invariant established elsewhere, or
   trusts an input from another layer, read enough of that other code to judge
   whether the assumption actually holds. A bug is often the gap between what
   one function guarantees and what its caller assumes.
6. Note the language and its edition/version, plus the declared dependency
   versions — `Cargo.toml` / `Cargo.lock` for Rust, `pyproject.toml` / `uv.lock`
   for Python, `build.zig` / `build.zig.zon` for Zig, or the equivalent
   manifest+lockfile for whatever language the target is in. You'll use these to
   judge whether the code is idiomatic for the version in use.

## What to look for — in priority order

Search in this order and present findings in this order. A confirmed bug
outranks any number of style nits.

1. **Bugs & uncovered edge cases** — the highest-value findings. Look for:
   - Inputs the code doesn't handle: empty/`None`/zero-length, boundary values,
     Unicode vs. byte offsets, very large inputs, negative numbers, overflow.
   - Error paths, e.g.:
     - Rust: `unwrap()`/`expect()`/`panic!` on fallible operations, `?` that
       discards context, a `Result` ignored via `let _ =`.
     - Python: bare `except:` or `except Exception: pass` that swallows errors,
       an unchecked `None` return dereferenced, an unhandled `KeyError`/`IndexError`.
     - Zig: `catch unreachable`/`orelse unreachable` on fallible operations,
       `.?` unwrapping an optional that can be null, an error union ignored via
       `_ = foo()` instead of `try`.
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
   language, and consistency with the surrounding code — e.g.:
   - Rust: iterator chains vs. manual loops, `if let`/`match` ergonomics,
     needless `clone()`, `?` vs. manual matching on `Result`.
   - Python: comprehensions vs. manual accumulation loops, `with` context
     managers vs. manual open/close, EAFP over LBYL, f-strings over `%`/`.format`.
   - Zig: `defer`/`errdefer` for cleanup, `comptime` where it fits, slices over
     manual index bookkeeping, following the explicit-allocator convention.

   Common to all: naming, dead code, error-handling idioms. Keep these last and
   keep them brief; do not let style noise bury a real bug.

## Documentation alignment

While reading, check the code against every claim made about it: inline
comments, doc comments/docstrings, `README.md`, and any project docs
(`dig/EXPLAINED.md`, `dig/DIAGRAMS.md`, design notes). When code and documentation
disagree — a comment describing behaviour the code no longer has, a README flag
that doesn't exist, a docstring with the wrong return contract — **report the
mismatch and ask the user which side is wrong**: should the code change to match
the docs, or the docs change to match the code? Do not silently "fix" either;
the mismatch itself is the finding, and only the user knows which was intended.
Use `AskUserQuestion` when there are a few discrete mismatches to resolve.

## Version currency

Checking whether dependency or language versions are out of date is out of
scope for this skill — that's the `updates` skill's job. If, while analysing, you
notice the target depends on something conspicuously old, mention it in one line
and point the user at `updates` for a proper currency check; don't start fetching
release notes here.

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
- This skill reports; it does not edit code. After presenting, offer to fix
  specific findings if the user wants — but make that a separate, explicit step.

## Saving findings

- Once you've presented the findings, ask the user whether they want you to save
  them to `dig/ISSUES.md`, or whether they have follow-up questions. Keep asking
  after each answer until the user tells you to either save or discard.
- Once the user confirmed saving to `dig/ISSUES.md` or discarding the
  explanation, if there were `:i` comments in the file(s) you explained 
  ask if the user wants you to delete those comments. Do not touch `:i` in other
  files.
- When saving, append the findings under a dated, scope-labelled heading rather
  than overwriting the file, so `dig/ISSUES.md` accumulates a history. Keep each
  entry's `file_path:line_number` anchors and severity grouping intact. When a
  previously recorded finding has since been fixed, mark it resolved rather than
  silently dropping it.
