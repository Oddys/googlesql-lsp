---
name: draw
description: Draws diagrams (sequence diagrams, architecture/component diagrams, flowcharts, data lineage diagrams) illustrating the structure and interactions of components in this project. Use when the user says "draw X", "diagram X", "show me how X talks to Y", asks to visualize an architecture, flow, or protocol, or as a follow-up to calling the `explain` skill.
---

# Draw

Produce a diagram of real project structure or behavior — not a generic
textbook illustration. Output is a single self-contained local HTML file
with inline SVG. Never uploaded anywhere; the user opens it directly in a
browser.

## Before drawing

1. Identify exactly what's being diagrammed and the right diagram shape:
   - **Sequence diagram** — messages/calls between actors over time (e.g.
     "how does the editor talk to the server", a request lifecycle, a
     protocol handshake). Use lifelines + arrows.
   - **Architecture / component diagram** — static structure: modules,
     processes, data stores, and the relationships between them. Use
     boxes + connecting lines, grouped by layer or crate/package.
   - **Flowchart** — control flow or decision logic inside one component
     (branches, loops, early returns).
   - **Data lineage diagrams** - how data flows from upstream to downstream tables
   If the request is ambiguous about scope or shape, ask rather than guess.
2. Read the relevant source file(s) in full before drawing. Every actor,
   message name, function name, and condition in the diagram must trace
   back to real code — grep/read as needed rather than diagramming from
   memory or from what a typical system "probably" does. If a detail is
   genuinely inferred rather than read (e.g. timing), say so in a note on
   the diagram itself rather than presenting it as fact.
3. Check `explained/DIAGRAMS.md` (create it if this is the first diagram)
   to see if this exact topic was already drawn. If so, ask whether to
   regenerate it in place or the user wants something different this time.
   If regenerating in place, treat it as a full redraw, not a patch —
   both this skill and the project may have moved on since the old file
   was written:
   - Re-read this SKILL.md's template and hard constraints fresh, and
     rebuild the diagram against them. Don't carry forward structure or
     CSS from the old file on the assumption it already conforms — the
     skill may have picked up new requirements (e.g. the sticky lane
     header, a footer format change) since that diagram was drawn.
   - Re-read the source file(s) the diagram cites, in full, as if drawing
     for the first time. Don't diff the old diagram against the new code
     and patch only what looks different — code the old diagram treated
     as stable may have been renamed, removed, or restructured. Confirm
     every actor, message, and condition still traces to real code before
     reusing it.
   - If the old diagram's sources no longer exist or the topic no longer
     maps cleanly onto the current code structure, say so and ask how to
     proceed rather than forcing the old shape onto new code.

## Output format — hard constraints

- **One self-contained `.html` file.** Inline `<style>` and `<script>`
  only. No CDN links, no external fonts, no JS libraries (no Mermaid,
  no D3) — hand-drawn inline SVG. It must open correctly via `file://`
  with no build step and no network access.
- **Never publish this file with the Artifact tool.** These diagrams stay
  local to the repo — do not upload them to Claude's cloud. Just `Write`
  the file and tell the user the path to open in a browser.
- **Every diagram must include a light/dark theme toggle** — a button
  that flips a `data-theme` attribute, persisted in `localStorage`, with
  `prefers-color-scheme` as the default before any preference is stored.
  Use the exact template below rather than inventing a new mechanism.
- Save to `explained/diagrams/<kebab-case-topic>.html` under the project root
  (create the `explained/diagrams/` directory if missing), and add an entry to
  `explained/DIAGRAMS.md` (create it if missing) pointing at it. `DIAGRAMS.md` is
  **only an index** — the detailed explanations live in `explained/prose/`, never
  here. Each entry is exactly two parts and nothing more:
  1. a `##` header linking the file: `## [`diagrams/<name>.html`](diagrams/<name>.html) — <short title>`
  2. a single short sentence (one line) saying what the diagram shows.
  Do **not** add sub-bullets, "key behavior" lists, source citations, file:line
  references, or any explanation of the concepts — those belong in the diagram
  itself and in `explained/prose/`.
- SVG must use `viewBox` (not fixed pixel width) and sit inside a
  horizontally-scrollable wrapper, so wide diagrams don't break layout.
- **Tall sequence diagrams need a frozen lane header, not a legend.** The
  actor/lane boxes are drawn once at the top of the SVG, so on a tall
  diagram (more than ~1 screen, e.g. multiple `PHASE` sections, viewBox
  height beyond ~900) they scroll out of view and the reader loses track
  of which lifeline is which. A flat list of colored dots next to the
  actor names is *not* enough — the reader still has to match a dot color
  to a lifeline color by eye, which is exactly the ambiguity we're trying
  to remove. Instead, literally duplicate the header `<g>` blocks (the
  same rects/text used at the top of the main SVG, cropped to just that
  row) into a second, small `position: sticky` SVG pinned above the
  diagram, and sync its horizontal scroll to the main diagram via JS —
  the frozen-header-row pattern spreadsheets use. See `.lane-sticky` /
  `.lane-sticky-scroll` in the template below. Skip it for short
  diagrams and for architecture/flowchart diagrams, where there's no
  header-scrolls-away problem.
- **Don't let the sticky copy render at the same time as the real
  header.** `position: sticky` keeps `.lane-sticky` in normal document
  flow until it would scroll past the viewport top — so at the very
  top of the page, both it *and* the real header `<g>` (drawn inside
  the main SVG, right below it) are on-screen at once, reading as a
  duplicated header row. Wrap the real header `<g>` blocks in the main
  SVG in `<g id="lane-header">` and hide `.lane-sticky` while that
  element is still visible, showing it only once the real header has
  scrolled out of frame — see the `IntersectionObserver` block at the
  end of the template's `<script>`. Do the visibility check
  synchronously on load (via `getBoundingClientRect()`) as well as on
  intersection change, so there's no flash of the duplicate before JS
  runs.
- **An activation bar (the thin "handler running" rect on a lifeline) must
  span the actor's full busy time — it must start no later than the request
  arrow that wakes it and end no earlier than the response arrow it sends.**
  Read the numbers directly off the coordinates rather than eyeballing the
  render: for a bar `<rect x=X y=TOP height=H .../>` on a given lifeline,
  every arrow whose endpoint touches that lifeline (`x1`/`x2` equal to `X`
  or `X+width`) that represents work happening *during* that activation must
  have `y` inside `[TOP, TOP+H]`. It's fine for the bar to start a few px
  before its request arrow and end a few px after its response arrow
  (existing diagrams use ~5-20px of padding, often to enclose one line of
  trailing annotation text) — that reads as normal breathing room. It is
  **not** fine for the bar to end *before* the response arrow's `y`: that
  leaves the response arrow, and often a note box describing what happened
  in between, floating below the bar with no activation behind them, which
  reads as the handler having already gone idle before it actually replied.
  When a bar covers a nested call to another actor
  (e.g. the server's bar around a subprocess round-trip), the nested actor
  gets its own, shorter bar for just the call/response pair, but the outer
  bar must keep running until *it* replies, not until the nested call
  returns. The layout verifier below checks this geometry automatically —
  but it can only do so because this file's conventions hold: message
  arrows drawn with `stroke="var(--ink)"` (as opposed to an actor's own
  accent color, used for symbolic/self-referential lines like a "repeat of
  the cycle above" pointer or a debounce hairpin) and `PHASE`-divider lines
  drawn with `stroke="var(--rule-soft)"` as full-width horizontal `<line>`s.
  Don't improvise different styling for these — the checker's phase-scoping
  is what lets it avoid matching a message against some unrelated activation
  bar that happens to reuse the same lifeline x hundreds of pixels away in
  a different phase.
- Cite sources in a footer as a **list or table, one source per row** —
  `path/to/file.rs:12-34` plus a short description of what it grounds —
  for every actor or message that came from a specific place in the code.
  Never collapse multiple sources onto one line; a reader scanning for a
  specific reference needs to find it without parsing a run-on sentence.

## Before calling it done — run the layout verifier, don't eyeball it

Hand-written SVG text never reliably fits its box or clears an arrow just
because the numbers look plausible — actual glyph width depends on the
rendering font's real metrics, and a cubic Bézier's visual peak is *not*
its control-point y (a symmetric curve's peak sits 25% of the way from
the control point toward the endpoint, `0.25*endpoint + 0.75*control`,
not at the control point itself).

After writing (or editing) the file, and again after any edit that
touches box dimensions, text content, or path/line coordinates, run:

```sh
.claude/skills/draw/scripts/verify-diagram.sh path/to/explained/diagrams/<name>.html
```

This renders the diagram in headless Chrome and checks, against the
*actual rendered geometry* (`getBBox()`, `getPointAtLength()` — not
hand-computed estimates), for:
- text wider than the `<rect>` it sits in (any note box or lane header),
- text extending past the SVG viewBox's margins,
- an arrow or curve physically crossing through any text's bounding box
  (its own caption or another one),
- for sequence diagrams: a request/response arrow (`stroke="var(--ink)"`)
  landing more than ~26px outside every activation bar it should belong to,
  within the same `PHASE` band — the "response floats below the bar that
  already ended" defect described above.

It exits 0 and prints `OK` when clean, or exits 1 with a JSON list of
every offending element (box/curve coordinates, overflow amount, the
crossing point) when not. **Do not present the diagram as finished, and
do not add it to `explained/DIAGRAMS.md`, while this reports issues.** Fix the
reported elements and re-run.

If no Chrome/Chromium is available, the script says so; take an actual
screenshot (e.g. via a headless-browser tool) and inspect it at 100%
zoom instead of skipping verification — don't fall back to reading the
SVG source and eyeballing the numbers.

When fixing overflow, prefer (in order): shortening the wording, then
widening the box if room exists before the next lane/lifeline, then
splitting into more lines — and when a box grows taller, either confirm
there's already enough gap before the next element to absorb it, or
shift every following element down and re-run the verifier to confirm
nothing else now collides. When fixing an arrow/text collision, don't
just nudge the control point by eye — either compute the target peak
with the formula above and solve for the control point, or increase
peak/caption clearance and re-run the verifier to confirm.

## Template

Start every diagram from this skeleton. Fill
in `<TITLE>`, the `--actorN` color variables, the legend, and the SVG body.
Keep the theme CSS block and the toggle script byte-for-byte; only the
content inside `.wrap` and the accent color values should change. The
`.lane-sticky` block (CSS, markup, and its scroll-sync script at the end)
is only for tall sequence diagrams — include or omit the whole trio
together, per the hard constraint above.

```html
<title><TITLE></title>
<style>
  :root {
    --paper: #f5f4ef;
    --panel: #ffffff;
    --ink: #1c2027;
    --ink-dim: #5b6270;
    --rule: rgba(28, 32, 39, 0.16);
    --rule-soft: rgba(28, 32, 39, 0.09);
    --note-bg: #fbf9f3;
    --note-border: #d8cfb8;
    /* one accent per actor/component — add as many as you need */
    --actor1: #4b5563;
    --actor2: #196b73;
    --actor2-soft: #e4f0ef;
    --actor3: #a8691f;
    --actor3-soft: #f4e8d7;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #12151a; --panel: #171b21; --ink: #e6e8ec; --ink-dim: #929aa8;
      --rule: rgba(230, 232, 236, 0.18); --rule-soft: rgba(230, 232, 236, 0.09);
      --note-bg: #1c1a14; --note-border: #453c28;
      --actor1: #9aa4b2; --actor2: #57bcc4; --actor2-soft: #172b2c;
      --actor3: #dba25b; --actor3-soft: #2c2214;
    }
  }
  :root[data-theme="dark"] {
    --paper: #12151a; --panel: #171b21; --ink: #e6e8ec; --ink-dim: #929aa8;
    --rule: rgba(230, 232, 236, 0.18); --rule-soft: rgba(230, 232, 236, 0.09);
    --note-bg: #1c1a14; --note-border: #453c28;
    --actor1: #9aa4b2; --actor2: #57bcc4; --actor2-soft: #172b2c;
    --actor3: #dba25b; --actor3-soft: #2c2214;
  }
  :root[data-theme="light"] {
    --paper: #f5f4ef; --panel: #ffffff; --ink: #1c2027; --ink-dim: #5b6270;
    --rule: rgba(28, 32, 39, 0.16); --rule-soft: rgba(28, 32, 39, 0.09);
    --note-bg: #fbf9f3; --note-border: #d8cfb8;
    --actor1: #4b5563; --actor2: #196b73; --actor2-soft: #e4f0ef;
    --actor3: #a8691f; --actor3-soft: #f4e8d7;
  }

  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--paper); color: var(--ink);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    padding: 40px 20px 64px;
  }
  .wrap { max-width: 1080px; margin: 0 auto; }
  header { margin-bottom: 28px; padding-bottom: 20px; border-bottom: 1px solid var(--rule); }
  .header-row { display: flex; align-items: flex-start; justify-content: space-between; gap: 24px; }
  .theme-toggle {
    flex: none; width: 38px; height: 38px; padding: 0;
    display: inline-flex; align-items: center; justify-content: center;
    border-radius: 9px; border: 1px solid var(--rule); background: var(--panel);
    color: var(--ink-dim); cursor: pointer;
  }
  .theme-toggle:hover { color: var(--actor2); border-color: var(--actor2); }
  .theme-toggle:focus-visible { outline: 2px solid var(--actor2); outline-offset: 2px; }
  .theme-toggle svg { width: 18px; height: 18px; }
  .theme-toggle .icon-moon { display: none; }
  :root[data-theme="dark"] .theme-toggle .icon-sun { display: none; }
  :root[data-theme="dark"] .theme-toggle .icon-moon { display: inline-flex; }
  .eyebrow {
    font-family: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
    font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--actor2); margin: 0 0 10px;
  }
  h1 { font-size: 26px; margin: 0 0 8px; text-wrap: balance; letter-spacing: -0.01em; }
  header p { margin: 0; max-width: 62ch; color: var(--ink-dim); font-size: 14.5px; line-height: 1.55; }
  .legend { display: flex; flex-wrap: wrap; gap: 18px; margin-top: 18px; font-size: 12.5px; color: var(--ink-dim); }
  .legend span { display: inline-flex; align-items: center; gap: 7px; }
  .legend svg { flex: none; }
  .diagram-shell { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; padding: 8px; }
  .diagram-scroll { overflow-x: auto; }
  /* only add this block + the .lane-sticky markup below for tall sequence diagrams — see "hard constraints" */
  .lane-sticky {
    position: sticky; top: 0; z-index: 5;
    background: var(--panel); border-bottom: 1px solid var(--rule);
    border-radius: 10px 10px 0 0;
    margin: -8px -8px 8px;
    padding: 6px 8px 2px;
  }
  /* overflow: hidden (not auto) — this scrolls only via the JS sync below, no independent scrollbar */
  .lane-sticky-scroll { overflow: hidden; }
  .lane-sticky-scroll svg { display: block; width: 100%; min-width: 760px; height: auto; }
  svg.diagram { display: block; min-width: 760px; width: 100%; height: auto; }
  text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
  .mono { font-family: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace; }
  footer { margin-top: 22px; color: var(--ink-dim); font-size: 12px; }
  footer .mono { color: var(--ink-dim); }
  .sources-label { margin: 0 0 8px; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ink-dim); }
  .sources { border-collapse: collapse; width: 100%; font-size: 12px; }
  .sources tr { border-top: 1px solid var(--rule-soft); }
  .sources tr:first-child { border-top: none; }
  .sources td { padding: 4px 16px 4px 0; vertical-align: top; line-height: 1.6; }
  .sources td:first-child { white-space: nowrap; color: var(--ink); }
</style>

<div class="wrap">
  <header>
    <div class="header-row">
      <div class="header-text">
        <p class="eyebrow"><!-- e.g. src/backend.rs — LanguageServer trait --></p>
        <h1><TITLE></h1>
        <p><!-- one or two sentences of framing --></p>
      </div>
      <button id="theme-toggle" class="theme-toggle" type="button" aria-pressed="false" aria-label="Switch to dark theme">
        <svg class="icon-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="4.2"/><path d="M12 2.5v2.4M12 19.1v2.4M4.6 4.6l1.7 1.7M17.7 17.7l1.7 1.7M2.5 12h2.4M19.1 12h2.4M4.6 19.4l1.7-1.7M17.7 6.3l1.7-1.7"/></svg>
        <svg class="icon-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a6.8 6.8 0 0 0 10.5 10.5Z"/></svg>
      </button>
    </div>
    <div class="legend"><!-- one <span> per arrow/box convention used below --></div>
  </header>

  <div class="diagram-shell">
    <!--
      Tall sequence diagrams only. This is a second, cropped SVG containing exact
      copies of the <g> header blocks from the main diagram below (same x/y/width,
      same colors) — not a redrawn summary. viewBox width and the .lane-sticky-scroll
      svg min-width above MUST match the main diagram's viewBox width and min-width,
      or the JS scroll sync will misalign the two.
    -->
    <div class="lane-sticky">
      <div class="lane-sticky-scroll">
        <svg viewBox="0 0 1080 76" xmlns="http://www.w3.org/2000/svg" role="presentation" aria-hidden="true">
          <!-- one <g> per actor, copy-pasted verbatim from the header <g> blocks in the main SVG below -->
        </svg>
      </div>
    </div>
    <div class="diagram-scroll">
      <svg class="diagram" viewBox="0 0 1080 800" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="<describe the diagram for screen readers>">
        <!-- sequence diagrams: lifelines + arrows, phase-labeled sections, like explained/diagrams/editor-lsp-sequence.html -->
        <!-- architecture diagrams: grouped boxes with rx corners, thin connecting lines, arrowheads for direction -->
        <!--
          Tall sequence diagrams only: wrap the real header <g> blocks (the same
          rects/text as the .lane-sticky copy above, id'd so the script at the
          bottom can hide the sticky copy while this is on-screen).
          <g id="lane-header"> ... one <g> per actor box ... </g>
        -->
      </svg>
    </div>
  </div>

  <footer>
    <p class="sources-label">Sources</p>
    <table class="sources">
      <tbody>
        <!-- one <tr> per source; first <td> is the path:line ref, second is what it grounds -->
        <tr><td class="mono"><!-- path/to/file.rs:12-34 --></td><td><!-- what this cites --></td></tr>
      </tbody>
    </table>
  </footer>
</div>

<script>
  (function () {
    var root = document.documentElement;
    var btn = document.getElementById('theme-toggle');
    var KEY = 'googlesql-lsp-diagram-theme';
    function systemPrefersDark() {
      return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    function apply(theme) {
      root.setAttribute('data-theme', theme);
      btn.setAttribute('aria-pressed', theme === 'dark' ? 'true' : 'false');
      btn.setAttribute('aria-label', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
    }
    var stored = null;
    try { stored = localStorage.getItem(KEY); } catch (e) {}
    apply(stored === 'dark' || stored === 'light' ? stored : (systemPrefersDark() ? 'dark' : 'light'));
    btn.addEventListener('click', function () {
      var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      apply(next);
      try { localStorage.setItem(KEY, next); } catch (e) {}
    });
  })();

  /* tall sequence diagrams only — keeps the frozen header's horizontal scroll in sync with the main diagram */
  (function () {
    var main = document.querySelector('.diagram-scroll');
    var header = document.querySelector('.lane-sticky-scroll');
    if (!main || !header) return;
    main.addEventListener('scroll', function () {
      header.scrollLeft = main.scrollLeft;
    });
  })();

  /* tall sequence diagrams only — show the sticky lane header only once the real
     header (id="lane-header", inside the main SVG) has scrolled out of view;
     otherwise both are visible at once at the top of the page and look duplicated */
  (function () {
    var sticky = document.querySelector('.lane-sticky');
    var realHeader = document.getElementById('lane-header');
    if (!sticky || !realHeader) return;
    function sync() {
      var r = realHeader.getBoundingClientRect();
      sticky.style.display = r.bottom > 0 ? 'none' : '';
    }
    sync();
    var obs = new IntersectionObserver(sync, { threshold: [0, 1] });
    obs.observe(realHeader);
    window.addEventListener('resize', sync);
  })();
</script>
```

## Style

- Ground every label in the actual code: real method names, real file
  names, real condition text — not paraphrases.
  Store line number(s) as a reference - by clicking on it the user
  should be able to go to the given line / first line of the given range in
  the corresponding file in this repository.
- Keep a legend for every visual convention introduced (solid vs. dashed
  arrows, box colors, note boxes) — a diagram nobody can decode is worse
  than prose.
- Prefer several small, focused diagrams over one diagram trying to show
  the entire system — split by protocol phase, by subsystem, or by call
  path if a single sequence would need more than ~8-10 messages.
- After writing the file, run `scripts/verify-diagram.sh` on it (see
  "Before calling it done" above) — fix anything it reports before
  moving on.
- After writing the file, tell the user the exact path and that they can
  open it directly in a browser (`file://` works, no server needed).
- Once done, ask if the user wants the diagram kept as-is, adjusted, or
  discarded — don't add it to `explained/DIAGRAMS.md` until they confirm
  they want to keep it.
