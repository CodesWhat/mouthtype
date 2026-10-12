/* ---------- direction configs ---------- */
// dot shape: 'sq' (soft square) or 'round'. mode: bottom | center | hbar.  shape0 = default silhouette.
const DIRS = {
  minimal: { id: 'minimal', name: 'M  Minimal (no readout)', blurb: 'same silhouette and motion as 2, plain bars and system text', plain: true,
    H: 30, shape0: 'capsule', win: 'none', padL: 12, padR: 12, slotI: 10, g1: 7, g2: 7,
    cols: 10, rows: 7, px: 4, py: 3, dw: 2, dh: 2, mode: 'center', timeStyle: 'plain', col: 'amber', glowPt: 0 },
  float: { id: 'float', name: '2  Floating Matrix', blurb: 'all-black capsule, round LED dots, no window',
    H: 30, shape0: 'capsule', win: 'none', padL: 12, padR: 12, slotI: 10, g1: 7, g2: 7,
    cols: 13, rows: 7, px: 3, py: 3, dw: 2, dh: 2, shape: 'round', rad: 0, mode: 'center', timeStyle: 'dot', col: 'amber', glowPt: 2.4 },
  window: { id: 'window', name: '1  Pager Window', blurb: 'capsule + inset pager window, bar segments',
    H: 30, shape0: 'capsule', win: 'inset', winInset: 3, padL: 11, padR: 11, slotI: 10, g1: 6, g2: 6,
    cols: 10, rows: 6, px: 4, py: 3, dw: 3, dh: 2, shape: 'sq', rad: 0.4, mode: 'bottom', timeStyle: 'seg', col: 'lcd', glowPt: 2.0 },
  twin: { id: 'twin', name: '3  Two-Zone', blurb: 'indicator well + divider + cool white matrix',
    H: 30, shape0: 'mid', win: 'well', padL: 4, padR: 12, slotI: 22, g1: 8, g2: 7,
    cols: 12, rows: 7, px: 3, py: 3, dw: 2, dh: 2, shape: 'sq', rad: 0.3, mode: 'bottom', timeStyle: 'dot', col: 'white', glowPt: 2.0 },
  face: { id: 'face', name: '4  Full-Face LCD', blurb: 'the whole capsule is the LCD, 7-seg clock',
    H: 30, shape0: 'capsule', win: 'full', padL: 12, padR: 12, slotI: 10, g1: 6, g2: 6,
    cols: 10, rows: 6, px: 4, py: 3, dw: 3, dh: 2, shape: 'sq', rad: 0.4, mode: 'bottom', timeStyle: 'seg', col: 'lcd', glowPt: 2.0 },
  sign: { id: 'sign', name: '5  Bargraph', blurb: 'one horizontal red LED bargraph with peak hold',
    H: 28, shape0: 'mid', win: 'none', padL: 11, padR: 11, slotI: 10, g1: 7, g2: 7,
    cols: 16, rows: 1, px: 3, py: 3, dw: 2, dh: 10, shape: 'sq', rad: 0.3, mode: 'hbar', timeStyle: 'dot', col: 'red', glowPt: 2.2 },
};
const REF = {
  classic: { id: 'classic', ref: true, name: 'Classic (current default)', blurb: '97 x 28 capsule, ten off-white bars', H: 28 },
  hifi: { id: 'hifi', ref: true, name: 'Hi-Fi (pixel slab)', blurb: '146 x 32 hardware slab, approximation', H: 32 },
};
const Opt = { label: 'dots', cardBtn: 'calm', shape: 'default', material: 'dark', finish: 'stop', bgLum: 0.1, color: null };
const SHAPE_KINDS = ['capsule', 'mid', 'squircle'];
// silhouette polygon: capsule and mid are circular corners (e=1); squircle is a superellipse corner (continuous curvature)
function shapePoly(kind, x, y, w, h, hr) {
  hr = hr || h; let a, e;
  if (kind === 'capsule') { a = Math.min(hr / 2, h / 2, w / 2); e = 1; }
  else if (kind === 'mid') { a = Math.min(0.4 * hr, h / 2, w / 2); e = 1; }
  else { a = Math.min(0.34 * hr * 1.32, h / 2, w / 2); e = 0.5; }
  const pts = [], N = 22, cs = [[x + w - a, y + a, -90], [x + w - a, y + h - a, 0], [x + a, y + h - a, 90], [x + a, y + a, 180]];
  for (const [cx, cy, deg0] of cs) for (let i = 0; i <= N; i++) {
    const t = (deg0 + 90 * i / N) * Math.PI / 180, c = Math.cos(t), s = Math.sin(t);
    pts.push([cx + a * Math.sign(c) * Math.pow(Math.abs(c), e), cy + a * Math.sign(s) * Math.pow(Math.abs(s), e)]);
  }
  return pts;
}
function shapePath(ctx, kind, x, y, w, h, S, hr) {
  const p = shapePoly(kind, x, y, w, h, hr); ctx.moveTo(p[0][0] * S, p[0][1] * S); for (let i = 1; i < p.length; i++) ctx.lineTo(p[i][0] * S, p[i][1] * S); ctx.closePath();
}
