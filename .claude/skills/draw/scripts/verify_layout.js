// Injected into a copy of the diagram HTML and run under headless Chrome
// (see verify-diagram.sh). Writes a JSON report into #verify-report on load.
// Finds two classes of real, rendered layout bugs that are easy to miss by
// eyeballing SVG source or even a screenshot at a glance:
//
//   1. boxIssues     — a <text> whose *rendered* glyph width (getBBox, real
//                      font metrics) exceeds the <rect> it sits inside, in
//                      the same <g>. Centered (text-anchor=middle) and
//                      left-aligned text are both handled.
//   2. globalIssues  — any <text> extending past the SVG viewBox's
//                      horizontal margins (would run off/get clipped).
//   3. pathIssues    — a <path> or <line> whose rendered geometry
//                      (sampled via getPointAtLength) physically crosses
//                      a <text> element's bounding box — i.e. an arrow
//                      drawn through its own (or another) label.
//
// Deliberately ignores the always-on vertical lifeline <line> elements
// (low-opacity, dashed, meant to run behind everything) — only flags
// solid/dashed *message* arrows and curved WIT-import paths.
function runLayoutVerification() {
  const svg = document.querySelector('svg.diagram') || document.querySelector('svg[viewBox]');
  if (!svg) {
    document.getElementById('verify-report').textContent = JSON.stringify({ error: 'no svg.diagram found' });
    return;
  }
  const vb = svg.getAttribute('viewBox').split(' ').map(Number);
  const [vx, , vw] = vb;

  const boxIssues = [];
  svg.querySelectorAll('g').forEach((g, gi) => {
    const rect = g.querySelector(':scope > rect');
    if (!rect) return;
    const rx = parseFloat(rect.getAttribute('x'));
    const ry = parseFloat(rect.getAttribute('y'));
    const rw = parseFloat(rect.getAttribute('width'));
    const rh = parseFloat(rect.getAttribute('height'));
    g.querySelectorAll(':scope > text').forEach((t) => {
      const bbox = t.getBBox();
      const anchor = t.getAttribute('text-anchor') || 'start';
      const tx = parseFloat(t.getAttribute('x'));
      const ty = parseFloat(t.getAttribute('y'));
      let allowed, overflowAmount, rightEdge;
      if (anchor === 'middle') {
        allowed = rw - 16;
        overflowAmount = bbox.width - allowed;
        rightEdge = tx + bbox.width / 2;
      } else {
        allowed = (rx + rw) - tx - 12;
        overflowAmount = bbox.width - allowed;
        rightEdge = tx + bbox.width;
      }
      const vOverflow = (ty > ry + rh + 2) || (ty - 14 < ry - 2);
      if (overflowAmount > 2 || rightEdge > rx + rw + 1 || vOverflow) {
        boxIssues.push({
          gi, text: t.textContent.slice(0, 70), fontSize: t.getAttribute('font-size'),
          rectXYWH: [rx, ry, rw, rh],
          overflowPx: Math.round(overflowAmount * 10) / 10, vOverflow
        });
      }
    });
  });

  const globalIssues = [];
  svg.querySelectorAll('text').forEach((t) => {
    const bbox = t.getBBox();
    if (bbox.width === 0) return;
    if (bbox.x < vx + 4 || bbox.x + bbox.width > vx + vw - 4) {
      globalIssues.push({ text: t.textContent.slice(0, 70), bboxX: Math.round(bbox.x), bboxRight: Math.round(bbox.x + bbox.width), viewBoxWidth: vw });
    }
  });

  const textBoxes = [];
  svg.querySelectorAll('text').forEach((t) => {
    const b = t.getBBox();
    if (b.width === 0) return;
    textBoxes.push({ x0: b.x - 2, x1: b.x + b.width + 2, y0: b.y - 2, y1: b.y + b.height + 2, str: t.textContent.slice(0, 60) });
  });
  const pathIssues = [];
  const seen = new Set();
  svg.querySelectorAll('path, line').forEach((el, i) => {
    // skip the always-on vertical lifelines: full-height, low-opacity, dashed "1,4"
    const opacity = parseFloat(el.getAttribute('opacity') || '1');
    const dash = el.getAttribute('stroke-dasharray') || '';
    const y1 = el.getAttribute('y1'), y2 = el.getAttribute('y2');
    const isLifeline = el.tagName === 'line' && opacity < 0.7 && dash === '1,4' && y1 === '74';
    if (isLifeline) return;

    let len;
    try { len = el.getTotalLength(); } catch (e) { return; }
    const steps = Math.max(20, Math.ceil(len / 3));
    for (let s = 0; s <= steps; s++) {
      const pt = el.getPointAtLength((s / steps) * len);
      for (const tb of textBoxes) {
        if (pt.x >= tb.x0 && pt.x <= tb.x1 && pt.y >= tb.y0 && pt.y <= tb.y1) {
          const key = i + '|' + tb.str;
          if (!seen.has(key)) {
            seen.add(key);
            const d = el.getAttribute('d');
            const label = d ? d.slice(0, 40) : (el.getAttribute('x1') + ',' + y1 + '->' + el.getAttribute('x2') + ',' + y2);
            pathIssues.push({ element: label, crossesText: tb.str, at: [Math.round(pt.x), Math.round(pt.y)] });
          }
        }
      }
    }
  });

  //   4. activationIssues — a request/response <line> (stroke="var(--ink)",
  //      this repo's convention for "real" message arrows, as opposed to
  //      symbolic/self-referential lines drawn in an actor's own accent
  //      color) whose endpoint sits on a lifeline that has an activation
  //      bar (a thin rect, width<=10, rx!=6/8 to exclude note boxes and
  //      lane-header boxes) in the same PHASE band, but lands more than
  //      SLACK px outside every such bar's [y, y+height] span. This is the
  //      "response arrow floats below the bar that supposedly sent it"
  //      defect class — see explained/diagrams/editor-lsp-sequence.html's git
  //      history (fixed 2026-07-11) for the worked example. Matches are
  //      scoped to the band between consecutive PHASE-divider lines
  //      (stroke="var(--rule-soft)", full-width horizontal) — without that,
  //      a lifeline's x gets reused across unrelated phases many hundreds
  //      of px apart, and "nearest rect anywhere in the file" produces
  //      false matches across phases that were never meant to relate.
  const SLACK = 26; // established padding in this repo's diagrams tops out ~22px
  const bandBounds = [0];
  svg.querySelectorAll('line').forEach((l) => {
    if ((l.getAttribute('stroke') || '') !== 'var(--rule-soft)') return;
    const ly1 = parseFloat(l.getAttribute('y1')), ly2 = parseFloat(l.getAttribute('y2'));
    if (ly1 === ly2) bandBounds.push(ly1);
  });
  bandBounds.push(1e9);
  bandBounds.sort((a, b) => a - b);
  function bandOf(y) {
    for (let i = 0; i < bandBounds.length - 1; i++) {
      if (y >= bandBounds[i] && y < bandBounds[i + 1]) return i;
    }
    return -1;
  }

  const activationRects = [];
  svg.querySelectorAll('rect').forEach((r) => {
    const w = parseFloat(r.getAttribute('width'));
    const h = parseFloat(r.getAttribute('height'));
    const rx = r.getAttribute('rx');
    if (w > 0 && w <= 10 && h > w * 2 && rx !== '6' && rx !== '8') {
      const x = parseFloat(r.getAttribute('x'));
      const y = parseFloat(r.getAttribute('y'));
      activationRects.push({ x, x2: x + w, y, h, band: bandOf(y) });
    }
  });

  const activationIssues = [];
  if (activationRects.length) {
    svg.querySelectorAll('line').forEach((line) => {
      if ((line.getAttribute('stroke') || '') !== 'var(--ink)') return;
      const x1 = parseFloat(line.getAttribute('x1')), y1 = parseFloat(line.getAttribute('y1'));
      const x2 = parseFloat(line.getAttribute('x2')), y2 = parseFloat(line.getAttribute('y2'));
      [[x1, y1], [x2, y2]].forEach(([x, y]) => {
        const b = bandOf(y);
        const touching = activationRects.filter((r) => r.band === b && (Math.abs(x - r.x) < 2 || Math.abs(x - r.x2) < 2));
        if (!touching.length) return;
        let best = Infinity;
        touching.forEach((r) => {
          const d = y < r.y ? r.y - y : (y > r.y + r.h ? y - (r.y + r.h) : 0);
          if (d < best) best = d;
        });
        if (best > SLACK) {
          activationIssues.push({ line: [x1, y1, x2, y2], endpoint: [Math.round(x), Math.round(y)], nearestGapPx: Math.round(best) });
        }
      });
    });
  }

  //   5. crossingIssues — a request/response <line> (stroke="var(--ink)")
  //      whose x-span passes clean through an activation bar's full width
  //      instead of stopping at the bar's *near* edge (the edge facing the
  //      other endpoint). This is the "arrow drawn crossing the bar instead
  //      of touching it" defect: a response line correctly touches a bar
  //      when it starts at the edge closest to where it's headed (e.g. a
  //      server bar sitting to the right of a client lifeline should be
  //      touched on its *left* edge by both the incoming request and the
  //      outgoing response) — anchoring the response at the bar's *far*
  //      edge instead means the line's rendered path necessarily overlaps
  //      the entire bar width to get there. Real bug first found in
  //      explained/diagrams/editor-lsp-sequence.html (fixed 2026-07-11): five
  //      response arrows anchored at the server bar's right edge (634)
  //      while heading left to the client (300), instead of the bar's left
  //      edge (626) that actually faces the client; same defect in
  //      explained/diagrams/internal-components-sequence.html for a bar facing a
  //      lifeline to its right. Detected as an *open-interval* overlap
  //      (excluding exact edge touches) between the line's [xa, xb] span
  //      and the bar's [x, x+width] span, scoped to the same PHASE band and
  //      same y-range as activationIssues above, so a plain "near edge"
  //      touch (which shares only the boundary point) is never flagged.
  const crossingIssues = [];
  if (activationRects.length) {
    svg.querySelectorAll('line').forEach((line) => {
      if ((line.getAttribute('stroke') || '') !== 'var(--ink)') return;
      const x1 = parseFloat(line.getAttribute('x1')), y1 = parseFloat(line.getAttribute('y1'));
      const x2 = parseFloat(line.getAttribute('x2')), y2 = parseFloat(line.getAttribute('y2'));
      if (y1 !== y2) return; // only horizontal message arrows have a meaningful x-span here
      const xa = Math.min(x1, x2), xb = Math.max(x1, x2);
      const b = bandOf(y1);
      const CROSS_EPS = 1;
      activationRects.forEach((r) => {
        if (r.band !== b) return;
        if (!(y1 >= r.y - 2 && y1 <= r.y + r.h + 2)) return;
        if (xa < r.x2 - CROSS_EPS && xb > r.x + CROSS_EPS) {
          crossingIssues.push({ line: [x1, y1, x2, y2], barXY: [r.x, r.y, r.x2 - r.x, r.h] });
        }
      });
    });
  }

  document.getElementById('verify-report').textContent = JSON.stringify({ boxIssues, globalIssues, pathIssues, activationIssues, crossingIssues }, null, 2);
}
window.addEventListener('load', runLayoutVerification);
