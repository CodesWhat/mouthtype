/* ---------- ordinary text font (Classic, Minimal, delivery cards). Never touches the LED display faces. ---------- */
const SYSF = 'system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", Arial, sans-serif';
const F_SERIF = '"Instrument Serif", Georgia, "Times New Roman", serif', F_SANS = '"Instrument Sans", ' + SYSF, F_MONO = '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace';
// [id, label, stack, flags]: single = one weight only (never ask for bold, it would be synthesised); inst = installed family, not embedded
const TF_OPTS = [
  ['isans', 'Instrument Sans', F_SANS, {}], ['iserif', 'Instrument Serif', F_SERIF, { single: 1 }], ['jbm', 'JetBrains Mono', F_MONO, {}],
  ['nerd', 'JetBrainsMono Nerd Font (installed on this Mac)', '"JetBrainsMono Nerd Font", "JetBrainsMono NF", ' + F_MONO, { inst: 'JetBrainsMono Nerd Font' }],
  ['geist', 'Geist Mono (installed on this Mac)', '"Geist Mono", ' + F_MONO, { inst: 'Geist Mono' }],
  ['system', 'System (SF Pro)', SYSF, {}], ['rounded', 'System Rounded', 'ui-rounded, "SF Pro Rounded", ' + SYSF, {}],
  ['serif', 'System Serif (New York)', 'ui-serif, "New York", Georgia, serif', {}], ['mono', 'System Mono', 'ui-monospace, "SF Mono", Menlo, monospace', {}],
  ['avenir', 'Avenir Next', '"Avenir Next", Avenir, "Helvetica Neue", sans-serif', {}], ['helv', 'Helvetica Neue', '"Helvetica Neue", Helvetica, Arial, sans-serif', {}],
  ['futura', 'Futura', 'Futura, "Avenir Next", sans-serif', {}], ['gill', 'Gill Sans', '"Gill Sans", "Gill Sans MT", "Helvetica Neue", sans-serif', {}],
  ['optima', 'Optima', 'Optima, Candara, "Helvetica Neue", sans-serif', {}], ['charter', 'Charter', 'Charter, "Bitstream Charter", Georgia, serif', {}],
  ['georgia', 'Georgia', 'Georgia, "Times New Roman", serif', {}], ['palatino', 'Palatino', 'Palatino, "Palatino Linotype", Georgia, serif', {}],
  ['typewriter', 'American Typewriter', '"American Typewriter", "Courier New", serif', {}], ['courier', 'Courier New', '"Courier New", Courier, monospace', {}],
  ['menlo', 'Menlo', 'Menlo, "SF Mono", monospace', {}], ['monaco', 'Monaco', 'Monaco, Menlo, monospace', {}],
];
const EMBED_LOADS = ['400 15px "Instrument Serif"', '400 13px "Instrument Sans"', '600 13px "Instrument Sans"', '500 12px "JetBrains Mono"'];
function loadTF() {
  const d = { family: 'system', custom: '', weight: 600, size: 0, preset: '' };
  try { const s = JSON.parse(localStorage.getItem('pm.textfont') || 'null'); if (s) Object.assign(d, s); } catch (e) {}
  return d;
}
function saveTF() { try { localStorage.setItem('pm.textfont', JSON.stringify(Opt.tf)); } catch (e) {} }
const _fc = document.createElement('canvas').getContext('2d');
let _instCache = {};
function fontInstalled(name) { // document.fonts.check() answers true for unknown families, so compare widths against the generics instead
  if (name in _instCache) return _instCache[name];
  const t = 'mmmmmmmmmmlliWWW 0123', w = f => { _fc.font = '72px ' + f; return _fc.measureText(t).width; };
  return _instCache[name] = ['monospace', 'serif', 'sans-serif'].some(g => w(`"${name}", ${g}`) !== w(g));
}
Opt.tf = loadTF();
const tfOpt = () => TF_OPTS.find(o => o[0] === Opt.tf.family) || TF_OPTS.find(o => o[0] === 'system');
function tfStack() {
  if (Opt.tf.preset === 'systema') return F_SANS;
  const c = (Opt.tf.custom || '').trim();
  if (c && fontInstalled(c)) return `"${c}", ${SYSF}`;
  return tfOpt()[2];
}
// effective weight for emphasised text: single-weight faces always 400
function tfWeight() { if (Opt.tf.preset === 'systema') return Opt.tf.weight; const c = (Opt.tf.custom || '').trim(); return !c && tfOpt()[3].single ? 400 : Opt.tf.weight; }
const tfKey = () => [Opt.tf.family, Opt.tf.custom, Opt.tf.weight, Opt.tf.size, Opt.tf.preset].join('|');
// role sizes in pt; the nudge applies to all. returns {fam, wt, px}
function tfSpec(role) {
  const sz = Opt.tf.size, W = Opt.tf.weight;
  if (Opt.tf.preset === 'systema') {   // headers and messages serif (2 pt larger, it runs small and light), data in JetBrains Mono
    if (role === 'msg') return { fam: F_SERIF, wt: 400, px: 15 + sz };
    if (role === 'classic') return { fam: F_SERIF, wt: 400, px: 14 + sz };
    if (role === 'rec') return { fam: F_MONO, wt: 500, px: 9 + sz };
    if (role === 'clock') return { fam: F_MONO, wt: 500, px: 11 + sz };
  }
  const base = { msg: 13, rec: 9.5, clock: 12, classic: 12 }[role];
  return { fam: tfStack(), wt: role === 'clock' ? Math.min(tfWeight(), 500) : tfWeight(), px: base + sz };
}
// faces for the LED pill/card Label font options that are system text
function labFace(lab) {
  if (lab === 'jbm') return { fam: F_MONO, wt: 500, px: 12 };
  if (lab === 'rounded') return { fam: 'ui-rounded, "SF Pro Rounded", ' + SYSF, wt: 600, px: 13 };
  return { fam: SYSF, wt: 600, px: 13 };
}
const tfFont = (sp, S) => `${sp.wt} ${sp.px * S}px ${sp.fam}`;
// draw text with its cap-height centred on yc (pt), so every face sits optically centred in the pill
function fillTextC(g, str, x, yc, S) {
  g.textBaseline = 'alphabetic'; const asc = g.measureText('H').actualBoundingBoxAscent || parseFloat(g.font) * 0.7;
  g.fillText(str, x * S, yc * S + asc / 2);
}
let _pmKey = '', _pm = null;
function plainMetrics() { // widths of REC and the clock with the current face, so slots never clip
  const k = tfKey(); if (k === _pmKey && _pm) return _pm; _pmKey = k;
  const r = tfSpec('rec'), c = tfSpec('clock'), f = s => `${s.wt} ${s.px}px ${s.fam}`;
  const dAdv = Math.max(...'0123456789'.split('').map(d => measure(d, f(c)))), cAdv = measure(':', f(c));
  return _pm = { recW: Math.max(22, Math.ceil(measure('REC', f(r)) + 3 * 0.9 + 1)), timeW: Math.max(26, Math.ceil(3 * dAdv + cAdv + 2)), dAdv, cAdv };
}
