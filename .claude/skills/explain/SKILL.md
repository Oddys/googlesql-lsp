---
name: explain
description: Explains the code in a file, a config file, or a project-related concept, assuming no prior knowledge of this codebase or domain beyond general software engineering. Use when the user says "explain X", "what does X do", "walk me through X", or asks to understand a concept used in this project.
---

# Explain

Produce a clear, self-contained explanation of a file, a piece of config, or a
project concept. Write for a competent software engineer who know general
programming, but nothing project-specific, except for specified in `EXPLAINED.md` 
(previously explained by invoking this skill).

## Before writing

1. Identify exactly what's being asked about: a specific file, a symbol
   inside a file, a config file, or a conceptual question ("how does X
   work here"). If ambiguous, ask.
2. Before answering a new question read `EXPLAINED.md` to identify what
   was explained so far. If being asked about something that has been already
   explained - ask the user if: 1) they you to repeat your previous explanation
   or 2) the explanation was not clear enough and they need rephrasing and
   simplification
3. Read the target file(s) in full — don't explain from a partial read or
   from memory of similar codebases.
3. If the file references other project-specific types, functions, or
   config keys that aren't self-evident, briefly look them up (grep/read)
   so the explanation is accurate rather than guessed. You don't need to
   fully trace every dependency — just enough to describe what a piece
   does and why, correctly.
4. If the file contains any comments that start with `:e` (e.g. `//:e` or `#:e`)
   make sure you address those questions in your explanation.
5. Define any domain or project-specific term the first time you use it
   (e.g. "LSP" → "Language Server Protocol, the standard editors use to
   talk to language tooling"). Don't assume the reader knows the project's
   internal vocabulary even if it's common within this repo.

## Structure the explanation

Adapt the shape to what's being explained, but generally cover:

**For a code file:**
- **Purpose** — one or two sentences: what problem this file/module
  solves and where it fits in the system (what calls it, what it calls).
- **Key pieces** — walk through the main exported symbols (functions,
  types, classes) in the order a reader would need them, not necessarily
  file order. Explain what each does and why it exists, not just what
  the syntax says.
- **Flow** — if there's a non-obvious control/data flow (e.g. request
  handling, a state machine, an algorithm), trace it step by step with
  a concrete example if that helps.
- **Non-obvious decisions** — call out anything that would confuse a
  newcomer: unusual patterns, workarounds, invariants, or constraints
  that aren't visible just from reading the code top to bottom.

**For a config file:**
- **Purpose** — what tool/system reads this file and when.
- **Section-by-section** — walk through each meaningful key/section,
  what it controls, and the practical effect of its current value
  (not just "sets X to Y" — explain what that changes in behavior).
- Skip boilerplate/default keys that don't affect behavior unless asked.

**For a concept** (e.g. "how does incremental parsing work here"):
- Start from the general/textbook version of the concept in one or two
  sentences (assume general SWE knowledge, not domain knowledge).
- Then explain the project's specific implementation/usage of it, with
  pointers to the relevant files/functions as concrete anchors.

## Style

- Use `file_path:line_number` references so the user can jump to the
  source, but don't just paraphrase code line-by-line — synthesize intent.
- Prefer prose and short lists over long code dumps; quote only the
  minimal snippet needed to anchor a point.
- Keep it proportional: a 30-line helper doesn't need the same depth as
  a core module. Match explanation length to complexity, not file size.
- Once done with the explanation, ask the user if they want you to save 
  this explanation to `EXPLAINED.md` or do they have more questions
  Proceed with asking after your every answer until the user tells
  you either to save or do not save your explanation. 
- Once the user confirmed saving to `EXPLAINED.md` or discarding the explanation,
  if there were `:e` comments in the file(s) you explained 
  ask if the user wants you to delete those comments. Do not touch `:e` in other
  files.
- Upon finishing check if `DIAGRAMS.md` does not contain obsolete or misleading
  descriptions. If it does - suggest to the user to call the `draw` skill 
  for the diagram that needs redrawing
