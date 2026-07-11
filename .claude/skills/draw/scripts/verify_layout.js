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

  document.getElementById('verify-report').textContent = JSON.stringify({ boxIssues, globalIssues, pathIssues }, null, 2);
}
window.addEventListener('load', runLayoutVerification);
