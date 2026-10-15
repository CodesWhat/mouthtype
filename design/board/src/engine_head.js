'use strict';
/* Mouthtype pill study: engine. Everything is drawn in points (pt); S = device px per pt. */
const TAU = Math.PI * 2;
const CW = 212, CH = 112;            // canvas size in pt (pill is centred inside)
const T = {                          // timings in ms (mirrored in spec.md)
  appear: 260, flashA: 110, flashB: 200, hide: 160, widthTau: 55, fadeIn: 120, fadeInDelay: 70,
  fadeOut: 50, procPeriod: 900, recBreath: 2000, record: 1000, msgAutoHide: 1400,
  attackTau: 28, releaseTau: 140, scrollSpeed: 36, scrollPauseA: 700, scrollPauseB: 900,
};

/* ---------- bitmap faces ---------- */
function bm(spec) { const o = {}; for (const k in spec) o[k] = spec[k].split('/'); return o; }
/*FONTS*/
const F5 = bm(F5SPEC), F3 = bm(F3SPEC);
F3[':'] = ['.', '#', '.', '#', '.']; F3['.'] = ['.', '.', '.', '.', '#']; F3[' '] = ['..', '..', '..', '..', '..'];
F5[' '] = ['...', '...', '...', '...', '...', '...', '...'];
const G = {
  lock: ['.###.', '#...#', '#...#', '#####', '##.##', '##.##', '#####'],
  x5: ['#...#', '.#.#.', '..#..', '.#.#.', '#...#'],
  sq4: ['####', '####', '####', '####'],
  star: ['...#...', '..###..', '#######', '.#####.', '..###..', '.##.##.', '.#...#.'],
  check: ['......#', '.....#.', '#...#..', '.#.#...', '..#....'],
  spark: ['...#...', '...#...', '...#...', '#######', '...#...', '...#...', '...#...'],
};
const glyphW = (f, ch) => (f[ch] || f['?'])[0].length;
const textCols = (s, f) => { let n = 0; for (const ch of s) n += glyphW(f, ch); return n + Math.max(0, s.length - 1); };

/* ---------- colour sets (readout) ---------- */
const COLORS = {
  lcd:   { name: 'Pager LCD', kind: 'lcd', ink: '#1d2815', face: ['#bfcaa6', '#aab691'], ghost: 0.09, rec: '#1d2815', err: '#6e2312', glow: 0 },
  amber: { name: 'Amber', kind: 'led', ink: '#ffb327', face: ['#0d0c0a', '#0d0c0a'], ghost: 0.11, rec: '#ff4a3c', err: '#ff4a3c', glow: '#ff9a10' },
  red:   { name: 'Red', kind: 'led', ink: '#ff3d32', face: ['#0d0a0a', '#0d0a0a'], ghost: 0.12, rec: '#ff3d32', err: '#ff7a6e', glow: '#ff2a20' },
  white: { name: 'Cool white', kind: 'led', ink: '#e8f1ff', face: ['#0b0c0e', '#0b0c0e'], ghost: 0.10, rec: '#ff4a40', err: '#ff5a4e', glow: '#78aefc' },
};
const THEMES = {
  dark:  { body: ['#252528', '#19191b'], stroke: 'rgba(255,255,255,0.15)', hi: 'rgba(255,255,255,0.07)', shadow: ['rgba(0,0,0,0.50)', 'rgba(0,0,0,0.35)'],
           btn: 'rgba(255,255,255,0.09)', btnHover: 'rgba(255,255,255,0.17)', btnPress: 'rgba(255,255,255,0.26)', glyph: 'rgba(255,255,255,0.88)', winEdge: 'rgba(255,255,255,0.06)' },
  light: { body: ['#fbfbfc', '#e6e6ea'], stroke: 'rgba(0,0,0,0.16)', hi: 'rgba(255,255,255,0.9)', shadow: ['rgba(0,0,0,0.20)', 'rgba(0,0,0,0.20)'],
           btn: 'rgba(0,0,0,0.07)', btnHover: 'rgba(0,0,0,0.13)', btnPress: 'rgba(0,0,0,0.2)', glyph: 'rgba(0,0,0,0.72)', winEdge: 'rgba(255,255,255,0.7)' },
};

/* ---------- helpers ---------- */
const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const eo3 = p => 1 - Math.pow(1 - clamp(p), 3);
const ei2 = p => clamp(p) * clamp(p);
function rrp(ctx, x, y, w, h, r, S) { ctx.roundRect(x * S, y * S, w * S, h * S, Math.min(r, w / 2, h / 2) * S); }
function cell(ctx, x, y, w, h, S, round, rad) {
  const x0 = Math.round(x * S), y0 = Math.round(y * S), x1 = Math.round((x + w) * S), y1 = Math.round((y + h) * S);
  if (round) { ctx.beginPath(); ctx.ellipse((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2, 0, 0, TAU); ctx.fill(); }
  else if (rad > 0) { ctx.beginPath(); ctx.roundRect(x0, y0, x1 - x0, y1 - y0, rad * S); ctx.fill(); }
  else ctx.fillRect(x0, y0, x1 - x0, y1 - y0);
}
function bitmap(ctx, rows, x, y, pitch, dot, S, round, rad) {
  for (let r = 0; r < rows.length; r++) for (let c = 0; c < rows[r].length; c++)
    if (rows[r][c] === '#') cell(ctx, x + c * pitch, y + r * pitch, dot, dot, S, round, rad);
}
function textBM(ctx, str, font, x, y, pitch, dot, S, round, rad) {
  let cx = x;
  for (const ch of str) { const g = font[ch] || font['?']; bitmap(ctx, g, cx, y, pitch, dot, S, round, rad); cx += (g[0].length + 1) * pitch; }
}
function hex(c, a) { // '#rrggbb' + alpha -> rgba()
  const n = parseInt(c.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`;
}

/* ---------- seven segment (px space) ---------- */
const SEG = { 0: 'abcdef', 1: 'bc', 2: 'abdeg', 3: 'abcdg', 4: 'bcfg', 5: 'acdfg', 6: 'acdefg', 7: 'abc', 8: 'abcdefg', 9: 'abcdfg' };
function segDigit(ctx, d, x, y, w, h, t, ghost, ink, ghostA) {
  const g = Math.max(0.6, t * 0.18), hh = t / 2;
  const hor = yc => [[x + g, yc], [x + g + hh, yc - hh], [x + w - g - hh, yc - hh], [x + w - g, yc], [x + w - g - hh, yc + hh], [x + g + hh, yc + hh]];
  const ver = (xc, y0, y1) => [[xc, y0 + g], [xc + hh, y0 + g + hh], [xc + hh, y1 - g - hh], [xc, y1 - g], [xc - hh, y1 - g - hh], [xc - hh, y0 + g + hh]];
  const ym = y + h / 2;
  const P = {
    a: hor(y + hh), g: hor(ym), d: hor(y + h - hh),
    f: ver(x + hh, y, ym), b: ver(x + w - hh, y, ym), e: ver(x + hh, ym, y + h), c: ver(x + w - hh, ym, y + h),
  };
  const on = SEG[d] || '';
  for (const k of 'abcdefg') {
    const lit = on.includes(k);
    if (!lit && !ghost) continue;
    ctx.globalAlpha = lit ? 1 : ghostA; ctx.fillStyle = ink;
    ctx.beginPath(); P[k].forEach((p, i) => i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1])); ctx.closePath(); ctx.fill();
  }
  ctx.globalAlpha = 1;
}


/* ---------- 14-segment caps (cheap: round-capped strokes in px space) ---------- */
const S14 = {
  A: 'abcefg1g2', B: 'abcdilg2', C: 'adef', D: 'abcdil', E: 'adefg1g2', F: 'aefg1g2', G: 'acdefg2', H: 'bcefg1g2', I: 'adil', J: 'bcde', K: 'efg1jm', L: 'def', M: 'bcefhj', N: 'bcefhm',
  O: 'abcdef', P: 'abefg1g2', Q: 'abcdefm', R: 'abefg1g2m', S: 'acdfg1g2', T: 'ail', U: 'bcdef', V: 'efkj', W: 'bcefkm', X: 'hjkm', Y: 'hjl', Z: 'ajkd',
  0: 'abcdefjk', 1: 'bc', 2: 'abdeg1g2', 3: 'abcdg2', 4: 'bcfg1g2', 5: 'acdfg1g2', 6: 'acdefg1g2', 7: 'abc', 8: 'abcdefg1g2', 9: 'abcdfg1g2', '-': 'g1g2', '!': 'il', '?': 'abg2l',
};
function seg14Lines(x, y, w, h) {
  const x1 = x + w, xm = x + w / 2, y1 = y + h, ym = y + h / 2;
  return { a: [x, y, x1, y], b: [x1, y, x1, ym], c: [x1, ym, x1, y1], d: [x, y1, x1, y1], e: [x, ym, x, y1], f: [x, y, x, ym], g1: [x, ym, xm, ym], g2: [xm, ym, x1, ym],
    h: [x, y, xm, ym], i: [xm, y, xm, ym], j: [x1, y, xm, ym], k: [x, y1, xm, ym], l: [xm, ym, xm, y1], m: [xm, ym, x1, y1] };
}
// draws caps text with 14-segment glyphs in px space; returns advance end. ghost>0 draws unlit segments at that alpha.
function seg14Text(ctx, str, x, yTop, capH, adv, S, color, alpha, ghost) {
  const w = capH * 0.56, t = Math.max(1, Math.round(capH * 0.11 * S)), g = t * 0.55;
  ctx.lineCap = 'round'; ctx.lineWidth = t; ctx.strokeStyle = color;
  let cx = x * S;
  for (const raw of str.toUpperCase()) {
    const on = (S14[raw] || '').match(/g1|g2|[a-fh-m]/g) || [];
    if (raw !== ' ') {
      const L = seg14Lines(cx + t / 2, yTop * S + t / 2, w * S - t, capH * S - t);
      for (const k in L) {
        const lit = on.includes(k); if (!lit && !(ghost > 0)) continue;
        const [x0, y0, x1, y1] = L[k], dx = x1 - x0, dy = y1 - y0, len = Math.hypot(dx, dy), ux = dx / len, uy = dy / len;
        ctx.globalAlpha = lit ? alpha : ghost; ctx.beginPath(); ctx.moveTo(x0 + ux * g, y0 + uy * g); ctx.lineTo(x1 - ux * g, y1 - uy * g); ctx.stroke();
      }
    }
    cx += adv * S;
  }
  ctx.globalAlpha = 1; return cx / S;
}
