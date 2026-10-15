/* ---------- meter ---------- */
class Meter {
  constructor(n) { this.n = n; this.v = new Float32Array(n); this.off = new Float32Array(n).fill(1); this.ph = 0; this.peak = 0; this.peakT = 0; }
  update(dt, level) {
    this.ph += dt;
    if (this.ph > 85) { this.ph = 0; for (let i = 0; i < this.n; i++) this.off[i] = 0.72 + Math.random() * 0.44; }
    const ka = 1 - Math.exp(-dt / T.attackTau), kr = 1 - Math.exp(-dt / T.releaseTau);
    for (let i = 0; i < this.n; i++) {
      const prof = 0.62 + 0.38 * Math.sin(Math.PI * (i + 0.5) / this.n);
      const t = clamp(level * prof * this.off[i]);
      this.v[i] += (t - this.v[i]) * (t > this.v[i] ? ka : kr);
    }
    const m = this.mean() * 1.35;
    if (m >= this.peak) { this.peak = m; this.peakT = 380; } else { this.peakT -= dt; if (this.peakT < 0) this.peak = Math.max(m, this.peak - dt / 900); }
  }
  mean() { let s = 0; for (const x of this.v) s += x; return s / this.n; }
}

/* ---------- material / chrome ---------- */
function matInfo(mat, lum) {
  if (mat === 'dark') return { th: 'dark' };
  if (mat === 'light') return { th: 'light' };
  if (mat === 'smoke') return { glass: 1, smoke: 1, th: 'dark' };
  return { glass: 1, th: lum > 0.5 ? 'light' : 'dark' };
}
const SYS = '-apple-system, "SF Pro Text", "Helvetica Neue", Arial, sans-serif';
function innerShadow(g, S, polyFn, color, blur, dx, dy) {
  g.save(); g.beginPath(); polyFn(); g.clip();
  g.shadowColor = color; g.shadowBlur = blur * S; g.shadowOffsetX = dx * S; g.shadowOffsetY = dy * S;
  g.beginPath(); g.rect(-50 * S, -50 * S, g.canvas.width + 100 * S, g.canvas.height + 100 * S); polyFn(); g.fillStyle = '#000'; g.fill('evenodd'); g.restore();
}
// r: {x,y,w,h,hr,kind,mi,fm,col,lum}; fm: none|inset|well|full
function paintChrome(g, S, r) {
  const { x, y, w, h, hr, kind, mi, fm, col } = r, th = THEMES[mi.th];
  const poly = () => shapePath(g, kind, x, y, w, h, S, hr);
  const hair = Math.max(1, S * 0.5);
  // shadow
  if (mi.glass) {
    g.save(); g.beginPath(); poly(); g.shadowColor = mi.smoke ? 'rgba(0,0,0,0.38)' : 'rgba(0,0,0,0.26)'; g.shadowBlur = 16 * S; g.shadowOffsetY = 5 * S; g.fillStyle = '#000'; g.fill(); g.restore();
    g.save(); g.globalCompositeOperation = 'destination-out'; g.beginPath(); poly(); g.fill(); g.restore();
  } else {
    g.save(); g.beginPath(); poly(); g.shadowColor = th.shadow[0]; g.shadowBlur = 12 * S; g.shadowOffsetY = 4 * S; g.fillStyle = '#000'; g.fill();
    g.shadowColor = th.shadow[1]; g.shadowBlur = 2 * S; g.shadowOffsetY = 0.8 * S; g.fill(); g.restore();
  }
  // body
  g.beginPath(); poly();
  const gr = g.createLinearGradient(0, y * S, 0, (y + h) * S);
  if (fm === 'full') { gr.addColorStop(0, col.face[0]); gr.addColorStop(1, col.face[1]); }
  else if (r.black) { gr.addColorStop(0, '#171719'); gr.addColorStop(1, '#0e0e10'); }
  else if (mi.smoke) { gr.addColorStop(0, 'rgba(34,34,40,0.56)'); gr.addColorStop(1, 'rgba(10,10,14,0.66)'); }
  else if (mi.glass) {
    if (mi.th === 'light') { gr.addColorStop(0, 'rgba(255,255,255,0.46)'); gr.addColorStop(1, 'rgba(255,255,255,0.26)'); }
    else { gr.addColorStop(0, 'rgba(34,34,40,0.40)'); gr.addColorStop(1, 'rgba(12,12,16,0.50)'); }
  } else { gr.addColorStop(0, th.body[0]); gr.addColorStop(1, th.body[1]); }
  g.fillStyle = gr; g.fill();
  if (fm === 'full') {
    const sh = g.createLinearGradient(0, y * S, 0, (y + h) * S); sh.addColorStop(0, 'rgba(0,0,0,0.12)'); sh.addColorStop(0.3, 'rgba(0,0,0,0)'); sh.addColorStop(1, 'rgba(0,0,0,0.10)');
    g.save(); g.beginPath(); poly(); g.clip(); g.fillStyle = sh; g.fillRect(x * S, y * S, w * S, h * S); g.restore();
  }
  if (mi.glass) {
    innerShadow(g, S, poly, mi.th === 'light' ? 'rgba(0,0,0,0.22)' : 'rgba(0,0,0,0.38)', 3.2, 0, -1.6);   // soft bottom
    innerShadow(g, S, poly, 'rgba(255,255,255,0.55)', 2.4, 1.1, 1.1);                                       // lit top-left inner edge
    const rim = g.createLinearGradient(x * S, y * S, (x + w) * S, (y + h) * S);
    rim.addColorStop(0, 'rgba(255,255,255,0.95)'); rim.addColorStop(0.28, 'rgba(255,255,255,0.35)'); rim.addColorStop(0.6, 'rgba(255,255,255,0.08)'); rim.addColorStop(1, 'rgba(255,255,255,0.42)');
    g.beginPath(); shapePath(g, kind, x + 0.4, y + 0.4, w - 0.8, h - 0.8, S, hr); g.strokeStyle = rim; g.lineWidth = Math.max(1, S * 0.8); g.stroke();
    g.beginPath(); shapePath(g, kind, x - 0.3, y - 0.3, w + 0.6, h + 0.6, S, hr); g.strokeStyle = mi.th === 'light' ? 'rgba(0,0,0,0.10)' : 'rgba(0,0,0,0.30)'; g.lineWidth = hair; g.stroke();
  } else {
    g.beginPath(); shapePath(g, kind, x + 0.25, y + 0.25, w - 0.5, h - 0.5, S, hr);
    g.strokeStyle = fm === 'full' ? 'rgba(255,255,255,0.35)' : th.hi; g.lineWidth = hair; g.save(); g.beginPath(); poly(); g.clip(); g.beginPath(); shapePath(g, kind, x + 0.25, y + 0.25, w - 0.5, h - 0.5, S, hr); g.stroke(); g.restore();
    g.beginPath(); shapePath(g, kind, x + 0.25, y + 0.25, w - 0.5, h - 0.5, S, hr);
    g.strokeStyle = fm === 'full' ? 'rgba(40,52,28,0.55)' : th.stroke; g.lineWidth = hair; g.stroke();
  }
}
// DOM backdrop for glass: clip-path'd div with backdrop-filter behind the canvas
function glassBox(div, mi, kind, css, x, y, w, h, hr, vis, sc, ty, lum) {
  if (!mi.glass || vis <= 0) { div.style.display = 'none'; return; }
  const pts = shapePoly(kind, 0, 0, w * css, h * css, hr * css);
  const d = 'M' + pts.map(p => p[0].toFixed(2) + ' ' + p[1].toFixed(2)).join('L') + 'Z';
  const bf = mi.smoke ? 'blur(20px) saturate(1.5) brightness(0.78)' : `blur(16px) saturate(1.9) brightness(${lum > 0.5 ? 1.05 : 1.14})`;
  const s = div.style;
  s.display = 'block'; s.left = x * css + 'px'; s.top = y * css + 'px'; s.width = w * css + 'px'; s.height = h * css + 'px';
  s.clipPath = `path('${d}')`; s.backdropFilter = bf; s.webkitBackdropFilter = bf; s.opacity = vis;
  s.transformOrigin = `${(CW / 2 - x) * css}px ${(CH / 2 - y) * css}px`; s.transform = `translateY(${ty * css}px) scale(${sc})`;
}

/* ---------- text helpers ---------- */
let _mctx = null;
function measure(str, font) { _mctx = _mctx || document.createElement('canvas').getContext('2d'); _mctx.font = font; return _mctx.measureText(str).width; }
function wrapWords(words, fits) {
  const lines = []; let cur = '';
  for (const w of words) { const t = cur ? cur + ' ' + w : w; if (!cur || fits(t)) cur = t; else { lines.push(cur); cur = w; } }
  if (cur) lines.push(cur); return lines;
}

/* ---------- the pill ---------- */
class Pill {
  constructor(host, key, o = {}) {
    this.host = host; this.key = key; this.cfg = DIRS[key] || REF[key]; this.ref = !!this.cfg.ref;
    this.glassDiv = document.createElement('div'); this.glassDiv.className = 'glassbk';
    this.cv = document.createElement('canvas'); this.cv.className = 'pillcv';
    this.inner = document.createElement('div'); this.inner.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%'; host.appendChild(this.inner); this.inner.appendChild(this.glassDiv); this.inner.appendChild(this.cv);
    this.ctx = this.cv.getContext('2d'); this.lay = document.createElement('canvas'); this.ro = document.createElement('canvas');
    this.mat = null; this.colKey = null;
    this.phase = 'hidden'; this.tPhase = 0; this.vis = 0; this.content = 'rec'; this.tContent = 0; this.text = ''; this.clock = 0; this.t = 0; this.recT = 0;
    this.meter = new Meter(this.ref ? (key === 'classic' ? 10 : 16) : this.cfg.cols);
    this.hover = null; this.press = null; this.btns = []; this.onButton = null; this.ea = {}; this.winR = null; this.curW = null; this.curH = null;
    this.setScale(o.S || 2, o.css || 1);
    const cv = this.cv;
    cv.addEventListener('pointermove', e => this.pointer(e, 'move')); cv.addEventListener('pointerdown', e => this.pointer(e, 'down'));
    cv.addEventListener('pointerup', e => this.pointer(e, 'up')); cv.addEventListener('pointerleave', () => { this.hover = null; this.press = null; cv.style.cursor = ''; });
  }
  setScale(S, css) {
    this.S = S; this.css = css;
    for (const c of [this.cv, this.lay, this.ro]) { c.width = Math.ceil(CW * S); c.height = Math.ceil(CH * S); }
    this.cv.style.width = CW * css + 'px'; this.cv.style.height = CH * css + 'px';
    if (this.crop) { const c = this.crop; this.host.style.width = c[2] * css + 'px'; this.host.style.height = c[3] * css + 'px'; this.host.style.overflow = 'hidden'; this.inner.style.left = -c[0] * css + 'px'; this.inner.style.top = -c[1] * css + 'px'; this.inner.style.width = CW * css + 'px'; this.inner.style.height = CH * css + 'px'; }
    else { this.host.style.width = CW * css + 'px'; this.host.style.height = CH * css + 'px'; }
    this.lg = this.lay.getContext('2d'); this.rg = this.ro.getContext('2d');
  }
  setCrop(c) { this.crop = c; this.setScale(this.S, this.css); }
  get kind() { return Opt.shape === 'default' ? (this.cfg.shape0 || 'capsule') : Opt.shape; }
  get mi() { return matInfo(this.mat || Opt.material, Opt.bgLum); }
  get col() { return COLORS[this.colKey || Opt.color || this.cfg.col]; }
  pointer(e, kind) {
    const r = this.cv.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width * CW, y = (e.clientY - r.top) / r.height * CH;
    let hit = null;
    if (this.phase === 'shown') for (const b of this.btns) if (x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h) hit = b.id;
    this.cv.style.cursor = hit ? 'pointer' : '';
    if (kind === 'move') this.hover = hit;
    if (kind === 'down') this.press = hit;
    if (kind === 'up') { const p = this.press; this.press = null; if (p && p === hit && this.onButton) this.onButton(p); }
  }
  show(content, text) {
    if (this.phase === 'hidden' || this.phase === 'hiding') { this.phase = 'appearing'; this.tPhase = 0; this.curW = null; this.curH = null; this.clock = 0; }
    this.setContent(content || 'rec', text);
  }
  hide() { if (this.phase !== 'hidden') { this.phase = 'hiding'; this.tPhase = 0; this.visFrom = this.vis; } }
  setContent(c, text) {
    if (c !== this.content || (text || '') !== this.text) { this.tContent = c !== this.content ? 0 : this.tContent; }
    if (c !== this.content) { this.content = c; if (c === 'locked') this.clock = 0; if (c === 'record') this.recT = 0; }
    if ((text || '') !== this.text) { this.text = text || ''; this.scrollT = 0; }
  }
  elems() { return ['dot', 'lock', 'meter', 'rec', 'time', 'btn', 'text', 'star', 'proc']; }
  targets() {
    const k = this.content, tg = {};
    if (k === 'rec') { tg.dot = 1; tg.meter = 1; tg.rec = 1; }
    else if (k === 'locked') { tg.lock = 1; tg.meter = 1; tg.time = 1; tg.btn = 1; }
    else if (k === 'proc') { tg.dot = 1; tg.meter = 1; tg.proc = 1; }
    else if (k === 'msg' || k === 'err') { tg.dot = 1; tg.text = 1; }
    else if (k === 'record') { tg.star = 1; tg.text = 1; tg.meter = this.tContent < 320 ? 1 : 0; }
    return tg;
  }
  /* ---- layout (pt, pill-local) ---- */
  labMode() { return this.cfg.plain ? 'sans' : Opt.label; }
  textMode() { // how a message is set; depends on the label face
    const c = this.cfg, str = (this.text || ''), lab = this.labMode();
    const key = [str, Opt.long, c.id, lab, c.plain ? tfKey() : ''].join('|'); if (this._tm && this._tmKey === key) return this._tm;
    let tm;
    if (lab === 'sans' || lab === 'rounded' || lab === 'jbm') {
      const pf = c.plain, sp = pf ? tfSpec('msg') : labFace(lab);
      const f = `${sp.wt} ${sp.px}px ${sp.fam}`, maxW = 150, w1 = measure(str, f), lh = Math.max(16, Math.round(sp.px * 1.25));
      const base = { face: 'plain', fam: sp.fam, wt: sp.wt, px: sp.px, lh };
      if (w1 <= 168) tm = { ...base, lines: [str], tw: w1, scroll: false };
      else if (Opt.long === 'scroll') tm = { ...base, lines: [str], tw: w1, vw: 150, scroll: true };
      else { const ls = wrapWords(str.split(' '), t => measure(t, f) <= maxW); tm = { ...base, lines: ls, tw: Math.max(...ls.map(l => measure(l, f))), scroll: false }; }
    } else {
      const u = str.toUpperCase(), seg = lab === 'seg';
      const w5 = seg ? Math.max(0, u.length * 11 - 3) : textCols(u, F5) * 2, w3 = s => seg ? Math.max(0, s.length * 8 - 2) : textCols(s, F3) * 2;
      if (w5 <= 156) tm = { lines: [u], tw: w5, face: seg ? 'S14' : 'F5', lh: 18, scroll: false };
      else if (Opt.long === 'scroll') tm = { lines: [u], tw: w5, vw: 140, face: seg ? 'S14' : 'F5', lh: 18, scroll: true };
      else { const ls = wrapWords(u.split(' '), t => w3(t) <= 148); tm = { lines: ls, tw: Math.max(...ls.map(w3)), face: seg ? 'S10' : 'F3', lh: 14, scroll: false }; }
    }
    this._tmKey = key; this._tm = tm; return tm;
  }
  layout(content, text) {
    const c = this.cfg, kind = this.kind;
    if (this.ref) return this.layoutRef(content, text);
    const mW = (c.cols - 1) * c.px + c.dw;
    const fm = this.faceMode(), wi = c.winInset ?? 3;
    const xi = c.padL, xm = xi + c.slotI + c.g1, xt = xm + mW + c.g2;
    const pmx = c.plain ? plainMetrics() : null, Wrec = xt + (pmx ? pmx.recW : 22) + c.padR, L = { xi, xm, xt, mW, fm, H: c.H };
    if (content === 'locked') {
      const tEnd = xt + (pmx ? pmx.timeW : 26);
      if (fm === 'inset') { L.winR = tEnd + (c.padR - wi); L.b1 = L.winR + 4; } else { L.winR = null; L.b1 = tEnd + 7; }
      L.b2 = L.b1 + 20 + 3; L.W = L.b2 + 20 + 5;
    } else if (content === 'msg' || content === 'err' || content === 'record') {
      const tm = this.textMode(); L.tm = tm;
      const iw = content === 'record' ? 14 : c.slotI;
      L.xtxt = xi + Math.max(iw, c.slotI) + c.g1;
      const vis = tm.scroll ? tm.vw : tm.tw;
      L.W = Math.max(Wrec, L.xtxt + vis + c.padR);
      const lh = tm.lh, n = tm.lines.length;
      if (n > 1) L.H = Math.max(c.H, tm.face === 'plain' ? 14 + n * tm.lh : 16 + n * 10 + (n - 1) * 4);
      L.winR = fm === 'inset' ? L.W - wi : null;
    } else { L.W = Wrec; L.winR = fm === 'inset' ? Wrec - wi : null; }
    return L;
  }
  layoutRef(content, text) {
    const cc = this.cfg, str = this.text || ''; const L = { H: cc.H };
    if (this.key === 'classic') {
      const f = `${tfSpec('classic').wt} ${tfSpec('classic').px}px ${tfSpec('classic').fam}`;
      if (content === 'locked') L.W = 137;
      else if (content === 'msg' || content === 'err' || content === 'record') {
        const w1 = measure(str, f);
        if (w1 <= 150) L.W = Math.max(97, Math.round(w1) + 34);
        else { const ls = wrapWords(str.split(' '), t => measure(t, f) <= 150); L.lines = ls; L.W = Math.round(Math.max(...ls.map(l => measure(l, f)))) + 34; L.H = Math.max(28, 12 + ls.length * Math.round(tfSpec('classic').px * 1.3)); L.lh = Math.round(tfSpec('classic').px * 1.3); }
      } else L.W = 97;
    } else L.W = 146;
    return L;
  }
  faceMode() {
    const c = this.cfg, k = this.col.kind;
    if (c.plain) return 'none';
    if (k === 'lcd') return c.win === 'full' ? 'full' : 'inset';
    return c.win === 'full' ? 'none' : c.win;
  }
  step(dt, level) {
    this.t += dt; this.tPhase += dt; this.tContent += dt; this.scrollT = (this.scrollT || 0) + dt;
    if (this.phase === 'appearing') { this.vis = eo3(this.tPhase / T.appear); if (this.tPhase >= T.appear) this.phase = 'shown'; }
    else if (this.phase === 'shown') this.vis = 1;
    else if (this.phase === 'hiding') { this.vis = (this.visFrom ?? 1) * (1 - ei2(this.tPhase / T.hide)); if (this.tPhase >= T.hide) { this.phase = 'hidden'; this.vis = 0; } }
    const L = this.layout(this.content, this.text); this.L = L;
    if (this.curW === null) { this.curW = L.W; this.curH = L.H; this.winR = L.winR; }
    const k = 1 - Math.exp(-dt / T.widthTau);
    this.curW += (L.W - this.curW) * k; if (Math.abs(L.W - this.curW) < 0.05) this.curW = L.W;
    this.curH += (L.H - this.curH) * k; if (Math.abs(L.H - this.curH) < 0.05) this.curH = L.H;
    if (L.winR != null) { this.winR += (L.winR - this.winR) * k; if (Math.abs(L.winR - this.winR) < 0.05) this.winR = L.winR; }
    if (this.content === 'locked') this.clock += dt;
    if (this.content === 'record') this.recT += dt;
    const metered = this.content === 'rec' || this.content === 'locked' || (this.content === 'record' && this.tContent < 320);
    this.meter.update(dt, metered ? level : 0);
    const tg = this.targets();
    for (const key of this.elems()) {
      const want = tg[key] || 0, cur = this.ea[key] ?? 0;
      if (want > cur) { if (this.tContent >= T.fadeInDelay || this.phase === 'appearing') this.ea[key] = Math.min(want, cur + dt / T.fadeIn); }
      else this.ea[key] = Math.max(want, cur - dt / T.fadeOut);
    }
  }
  simulate(ms, levelFn) { const dt = 1000 / 60; for (let t = 0; t < ms; t += dt) this.step(dt, levelFn ? levelFn(t) : 0.3); }
  clockStr() { const s = Math.floor(this.clock / 1000); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
  scrollOffset(tw, vw) { // marquee: pause 700, scroll at SPEED pt/s, pause 900, jump back
    const span = Math.max(0, tw - vw), run = span / T.scrollSpeed * 1000, cyc = T.scrollPauseA + run + T.scrollPauseB;
    const t = this.scrollT % cyc;
    if (t < T.scrollPauseA) return 0; if (t < T.scrollPauseA + run) return span * (t - T.scrollPauseA) / run; return span;
  }

  /* ---- render ---- */
  render() {
    const S = this.S, ctx = this.ctx, mi = this.mi;
    ctx.clearRect(0, 0, this.cv.width, this.cv.height);
    if (this.phase === 'hidden' || !this.L) { this.glassDiv.style.display = 'none'; return; }
    this.lg.clearRect(0, 0, this.lay.width, this.lay.height); this.rg.clearRect(0, 0, this.ro.width, this.ro.height);
    this.btns = [];
    const W = this.curW, H = this.curH, ox = Math.round((CW - W) / 2), oy = Math.round((CH - H) / 2);
    this.geo = { ox, oy, W, H };
    if (this.ref) this.key === 'classic' ? this.paintClassic(this.lg, S, ox, oy, W, H) : this.paintHifi(this.lg, S, ox, oy);
    else this.paint(this.lg, this.rg, S, ox, oy, W, H);
    const e = this.vis, sc = 0.9 + 0.1 * e, ty = (1 - e) * 5;
    glassBox(this.glassDiv, mi, this.ref ? 'capsule' : this.kind, this.css, ox, oy, W, H, this.cfg.H, e, sc, ty, Opt.bgLum);
    ctx.save(); ctx.globalAlpha = e;
    ctx.translate(CW / 2 * S, (CH / 2 + ty) * S); ctx.scale(sc, sc); ctx.translate(-CW / 2 * S, -CH / 2 * S);
    ctx.drawImage(this.lay, 0, 0); ctx.restore();
  }
  flushReadout(glowColor, glowPt, S, strength = 1) {
    const g = this.lg;
    if (glowColor) {
      g.save(); g.globalCompositeOperation = 'lighter';
      g.filter = `blur(${glowPt * S}px)`; g.globalAlpha = 0.85 * strength; g.drawImage(this.ro, 0, 0);
      g.filter = `blur(${glowPt * 0.45 * S}px)`; g.globalAlpha = 0.45 * strength; g.drawImage(this.ro, 0, 0); g.restore();
    }
    g.drawImage(this.ro, 0, 0);
  }

  paint(g, rg, S, ox, oy, W, H) {
    const c = this.cfg, mi = this.mi, th = THEMES[mi.th], col = this.col, L = this.L, fm = this.faceMode(), kind = this.kind;
    const led = col.kind === 'led', lcd = !led, plain = !!c.plain;
    const yc = oy + H / 2, hair = Math.max(1, S * 0.5);
    const multi = L.tm && L.tm.lines.length > 1 && (this.content === 'msg' || this.content === 'err' || this.content === 'record');
    // chrome
    paintChrome(g, S, { x: ox, y: oy, w: W, h: H, hr: c.H, kind, mi, fm, col, black: c.win === 'full' && fm === 'none' });
    // window / well
    const ink = plain ? (mi.th === 'light' ? '#1d1d1f' : '#f4f3e8') : col.ink;
    const recCol = plain ? (mi.th === 'light' ? '#e0281c' : '#ff453a') : col.rec;
    const errCol = plain ? (mi.th === 'light' ? '#d70015' : '#ff6b5e') : col.err;
    if (fm === 'inset') {
      const wi = c.winInset ?? 3, wx = ox + wi, wy = oy + wi, ww = (ox + this.winR) - wx, wh = H - 2 * wi;
      const wp = () => shapePath(g, kind, wx, wy, ww, wh, S, wh);
      g.beginPath(); wp(); const wg = g.createLinearGradient(0, wy * S, 0, (wy + wh) * S); wg.addColorStop(0, col.face[0]); wg.addColorStop(1, col.face[1]); g.fillStyle = wg; g.fill();
      innerShadow(g, S, wp, lcd ? 'rgba(20,30,10,0.55)' : 'rgba(0,0,0,0.9)', 3.2, 0, 1.3);
      if (lcd) { g.save(); g.beginPath(); wp(); g.clip(); const gl = g.createLinearGradient(0, wy * S, 0, (wy + wh * 0.5) * S); gl.addColorStop(0, 'rgba(255,255,255,0.16)'); gl.addColorStop(1, 'rgba(255,255,255,0)'); g.fillStyle = gl; g.fillRect(wx * S, wy * S, ww * S, wh * 0.5 * S); g.restore(); }
      g.beginPath(); shapePath(g, kind, wx - 0.25, wy - 0.25, ww + 0.5, wh + 0.5, S, wh); g.strokeStyle = th.winEdge; g.lineWidth = hair; g.stroke();
    } else if (fm === 'well') {
      const dcx = ox + c.padL + c.slotI / 2;
      g.beginPath(); g.arc(dcx * S, yc * S, 11 * S, 0, TAU); g.fillStyle = mi.th === 'dark' ? 'rgba(0,0,0,0.42)' : 'rgba(0,0,0,0.08)'; g.fill();
      g.strokeStyle = mi.th === 'dark' ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.8)'; g.lineWidth = hair; g.stroke();
      const dx = Math.round(ox + c.padL + c.slotI + c.g1 / 2 + 0.5);
      g.fillStyle = mi.th === 'dark' ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.12)';
      g.fillRect(Math.round(dx * S), Math.round((yc - 7) * S), Math.max(1, Math.round(S * 0.5)), Math.round(14 * S));
    }

    // ---- readout
    const A = this.ea, ghostA = col.ghost, round = c.shape === 'round', rad = c.rad || 0, tg = S >= 2 ? 0.5 : 0;
    const lit = (color, a) => { rg.fillStyle = color; rg.globalAlpha = clamp(a); };
    const flash = this.phase === 'appearing' && this.tPhase > T.flashA && this.tPhase < T.flashB;
    const lab = this.labMode(), tplain = lab === 'sans' || lab === 'rounded' || lab === 'jbm', pxl = lab === 'pixel';
    const xi = ox + L.xi, xt = ox + L.xt, ym = multi ? oy + 8 + (L.tm.face === 'plain' ? 8 : 5) : yc; // y of first line centre for indicator
    // indicator dot
    if (A.dot > 0.01) {
      const cx = xi + c.slotI / 2, br = 0.78 + 0.22 * Math.sin(this.t / T.recBreath * TAU);
      const dc = this.content === 'rec' ? recCol : this.content === 'err' ? errCol : ink;
      let a = A.dot * (this.content === 'rec' ? br : 1);
      if (this.content === 'proc') a *= 0.55 + 0.35 * Math.sin(this.t / 260);
      if (this.content === 'err') a *= (Math.floor(this.tContent / 180) % 2 === 0 || this.tContent > 1100) ? 1 : 0.15;
      if (plain) { g.save(); g.globalAlpha = a; g.shadowColor = dc; g.shadowBlur = 5 * S; g.fillStyle = dc; g.beginPath(); g.arc(cx * S, ym * S, 3 * S, 0, TAU); g.fill(); g.restore(); }
      else { lit(dc, a); rg.beginPath(); rg.arc(cx * S, ym * S, 3 * S, 0, TAU); rg.fill(); }
    }
    // padlock
    if (A.lock > 0.01) {
      if (plain) { g.save(); g.globalAlpha = A.lock; g.fillStyle = ink; g.strokeStyle = ink; g.lineWidth = 1.6 * S; const lx = xi + 1, ly = yc;
        g.beginPath(); g.roundRect(lx * S, (ly - 1) * S, 8 * S, 6.5 * S, 1.6 * S); g.fill();
        g.beginPath(); g.arc((lx + 4) * S, (ly - 1.5) * S, 2.6 * S, Math.PI, 0); g.stroke(); g.restore(); }
      else { lit(ink, A.lock); bitmap(rg, G.lock, xi + (c.slotI - 10) / 2, yc - 7, 2, 2 - tg, S, round, rad); }
    }
    // meter
    if (A.meter > 0.01) this.paintMeter(g, rg, S, ox + L.xm, yc, A.meter, flash, ghostA, lcd, ink, plain);
    // REC label
    if (A.rec > 0.01) {
      if (plain || tplain) { g.save(); g.globalAlpha = 0.6 * A.rec; g.fillStyle = ink; const rs = plain ? tfSpec('rec') : { ...labFace(lab), px: 9.5 }; g.font = tfFont(rs, S); g.letterSpacing = (0.9 * S) + 'px'; fillTextC(g, 'REC', xt, yc, S); g.restore(); }
      else if (lab === 'seg') { rg.strokeStyle = ink; seg14Text(rg, 'REC', xt, yc - 5, 10, 8, S, ink, 0.62 * A.rec, 0); }
      else { lit(ink, 0.62 * A.rec); textBM(rg, 'REC', F3, xt, yc - 5, 2, lab === 'pixel' ? 2 : 2 - tg, S, lab === 'pixel' ? false : round, lab === 'pixel' ? 0 : rad); }
    }
    if (A.time > 0.01) this.paintTimer(g, rg, S, xt, yc, A.time, ghostA, ink, tg, round, rad, plain);
    if (A.proc > 0.01) {
      const ph = Math.floor(this.t / 220) % 4;
      for (let i = 0; i < 3; i++) {
        const a = A.proc * (i < ph ? 1 : 0.18);
        if (plain) { g.save(); g.globalAlpha = a * 0.9; g.fillStyle = ink; g.beginPath(); g.arc((xt + 1.5 + i * 6) * S, (yc + 0.5) * S, 1.5 * S, 0, TAU); g.fill(); g.restore(); }
        else { lit(ink, a); cell(rg, xt + i * 6, yc + 1, 2, 2, S, round, rad); }
      }
    }
    // message text
    if (A.text > 0.01 && L.tm) {
      const tm = L.tm, tcl = this.content === 'err' ? errCol : ink; let ta = A.text;
      if (this.content === 'record') { const t = this.tContent - 320; ta *= t < 0 ? 0 : (t < 400 ? ((Math.floor(t / 100) % 2 === 0) ? 1 : 0.1) : 1); }
      const x0 = ox + L.xtxt, nl = tm.lines.length, blockH = tm.face === 'plain' ? nl * tm.lh : (tm.face === 'F3' || tm.face === 'S10') ? nl * 10 + (nl - 1) * 4 : 14;
      const y0 = oy + (H - blockH) / 2;
      const clipW = tm.scroll ? tm.vw : tm.tw + 2, off = tm.scroll ? this.scrollOffset(tm.tw, tm.vw) : 0;
      const target = tm.face === 'plain' ? g : rg;
      target.save(); target.beginPath(); target.rect((x0 - 1) * S, (oy) * S, (clipW + 1) * S, H * S); target.clip();
      if (tm.face === 'plain') {
        g.globalAlpha = ta; g.fillStyle = tcl; g.font = `${tm.wt} ${tm.px * S}px ${tm.fam}`;
        tm.lines.forEach((ln, i) => fillTextC(g, ln, x0 - off, y0 + tm.lh / 2 + i * tm.lh, S));
      } else if (tm.face === 'S14' || tm.face === 'S10') {
        const cap = tm.face === 'S14' ? 14 : 10, adv = tm.face === 'S14' ? 11 : 8;
        tm.lines.forEach((ln, i) => seg14Text(rg, ln, x0 - off, y0 + i * (cap + 4), cap, adv, S, tcl, ta, 0));
      } else {
        lit(tcl, ta); const f = tm.face === 'F5' ? F5 : F3, hgt = tm.face === 'F5' ? 7 : 5;
        tm.lines.forEach((ln, i) => textBM(rg, ln, f, x0 - off, y0 + i * (hgt * 2 + 4), 2, pxl ? 2 : 2 - tg, S, pxl ? false : round, pxl ? 0 : rad));
      }
      target.restore();
    }
    // star (record)
    if (A.star > 0.01) {
      const sp = (Math.floor(this.recT / 180) % 2) ? G.spark : G.star;
      if (plain) { g.save(); g.globalAlpha = A.star; g.fillStyle = ink; const cx = xi + 7, cy = yc, R1 = 7, R2 = 3;
        g.beginPath(); for (let i = 0; i < 10; i++) { const r = i % 2 ? R2 : R1, a = -Math.PI / 2 + i * Math.PI / 5; g.lineTo((cx + r * Math.cos(a)) * S, (cy + r * Math.sin(a)) * S); } g.closePath(); g.fill(); g.restore(); }
      else { lit(ink, A.star); bitmap(rg, sp, xi, yc - 7, 2, 2 - tg, S, round, rad); }
    }
    rg.globalAlpha = 1; g.globalAlpha = 1;
    let glowK = 1; if (this.content === 'record') glowK = 1 + 0.9 * Math.exp(-this.recT / 260) + 0.25 * Math.sin(this.recT / 90);
    this.flushReadout(led && !plain ? col.glow : null, c.glowPt, S, glowK);
    if (A.btn > 0.01) this.paintButtons(g, S, ox, yc, A.btn, th, col, fm, kind, plain, ink, mi);
    if (this.content === 'record' && this.recT > 260 && this.recT < 900) {
      const p = (this.recT - 260) / 640, sx = ox + (-30 + (W + 60) * p);
      g.save(); g.beginPath(); shapePath(g, kind, ox, oy, W, H, S, c.H); g.clip();
      const sg = g.createLinearGradient((sx - 18) * S, 0, (sx + 18) * S, 0);
      sg.addColorStop(0, 'rgba(255,255,255,0)'); sg.addColorStop(0.5, 'rgba(255,255,255,' + (lcd ? 0.35 : 0.14) + ')'); sg.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = sg; g.fillRect(ox * S, oy * S, W * S, H * S); g.restore();
    }
  }
  paintMeter(g, rg, S, x0, yc, a, flash, ghostA, lcd, ink, plain) {
    const c = this.cfg, round = c.shape === 'round', rad = c.rad || 0, m = this.meter;
    const proc = this.content === 'proc', rec = this.content === 'record';
    const N = c.cols, R = c.rows, mid = (R - 1) / 2;
    const headPos = () => (Math.sin(this.t / T.procPeriod * TAU - Math.PI / 2) * 0.5 + 0.5) * (N - 1);
    if (c.mode === 'hbar') {
      const y = yc - c.dh / 2; let lvl = clamp(m.mean() * 1.35); const pk = m.peak;
      for (let i = 0; i < N; i++) {
        let al = ((i + 1) / N <= lvl + 0.001 || flash) ? 1 : 0;
        if (proc) al = clamp(1 - Math.abs(i - headPos()) / 3);
        if (rec) al = (i / N < clamp(this.tContent / 300)) ? 1 : 0;
        g.fillStyle = ink; g.globalAlpha = ghostA; cell(g, x0 + i * c.px, y, c.dw, c.dh, S, round, rad);
        const isPk = !proc && !rec && pk > 0.05 && Math.round(pk * N) === i + 1;
        if (al > 0 || isPk) { rg.fillStyle = (i >= N - 3 && !lcd) ? '#ff8a7a' : ink; rg.globalAlpha = clamp((al || 0.9) * a); cell(rg, x0 + i * c.px, y, c.dw, c.dh, S, round, rad); }
      }
      g.globalAlpha = 1; rg.globalAlpha = 1; return;
    }
    const rowsH = (R - 1) * c.py + c.dh, y0 = yc - rowsH / 2, full = c.mode === 'center' ? mid + 1 : R;
    for (let i = 0; i < N; i++) {
      let v = m.v[i], n;
      if (proc) { v = clamp(1 - Math.abs(i - headPos()) / 2.6) * 0.95; n = v > 0.05 ? Math.max(1, Math.round(v * full)) : 0; }
      else if (rec) n = Math.round(clamp((this.tContent / 300) * 1.6 - i / N * 0.6) * full);
      else n = v < 0.015 ? 0 : Math.max(1, Math.round(v * full));
      if (plain) { // vector bars, rounded, centred; same n as the dots
        const hgt = n === 0 ? 2 : n * 2 * c.py - (c.py - c.dh) * 1 - (c.py - c.dh), bw = c.dw;
        const hh = Math.max(2, (n === 0 ? 1 : (2 * n - 1)) * c.py - (c.py - c.dh)), bx = x0 + i * c.px;
        g.save(); g.fillStyle = ink; g.globalAlpha = a * (n === 0 ? 0.45 : 1); g.beginPath(); g.roundRect(bx * S, (yc - hh / 2) * S, bw * S, hh * S, bw / 2 * S); g.fill(); g.restore();
        continue;
      }
      for (let r = 0; r < R; r++) {
        let isLit = c.mode === 'center' ? Math.abs(r - mid) < n : r >= R - n;
        if (flash) isLit = true;
        const x = x0 + i * c.px, y = y0 + r * c.py;
        g.fillStyle = ink; g.globalAlpha = ghostA; cell(g, x, y, c.dw, c.dh, S, round, rad);
        if (isLit) { rg.fillStyle = ink; rg.globalAlpha = a; cell(rg, x, y, c.dw, c.dh, S, round, rad); }
        else if (!proc && !rec && n === 0 && r === (c.mode === 'center' ? Math.round(mid) : R - 1)) { rg.fillStyle = ink; rg.globalAlpha = 0.45 * a; cell(rg, x, y, c.dw, c.dh, S, round, rad); }
      }
    }
    g.globalAlpha = 1; rg.globalAlpha = 1;
  }
  paintTimer(g, rg, S, xt, yc, a, ghostA, ink, tg, round, rad, plain) {
    const c = this.cfg, s = this.clockStr();
    if (plain) {
      const cs = tfSpec('clock'), pm = plainMetrics(); g.save(); g.globalAlpha = a; g.fillStyle = ink; g.font = tfFont(cs, S); let x = xt;
      for (const ch of s) { const col = ch === ':', adv = col ? pm.cAdv : pm.dAdv; fillTextC(g, ch, x + (adv - measure(ch, `${cs.wt} ${cs.px}px ${cs.fam}`)) / 2, yc, S); x += adv; } g.restore();
    } else if (c.timeStyle === 'seg') {
      const dw = 6 * S, dh = 11 * S, t = Math.max(1, Math.round(1.5 * S)), gap = 2 * S; let x = xt * S; const y = (yc - 5.5) * S;
      for (const ch of s) {
        if (ch === ':') { const cs = Math.max(1, Math.round(1.5 * S)); for (const yy of [y + dh * 0.3, y + dh * 0.7]) { rg.globalAlpha = a; rg.fillStyle = ink; rg.fillRect(Math.round(x + 0.3 * S), Math.round(yy - cs / 2), cs, cs); } x += 2 * S + gap; continue; }
        segDigit(g, -1, x, y, dw, dh, t, true, ink, ghostA);
        rg.globalAlpha = a; segDigit(rg, +ch, x, y, dw, dh, t, false, ink, 0); x += dw + gap;
      }
      rg.globalAlpha = 1;
    } else { rg.fillStyle = ink; rg.globalAlpha = a; textBM(rg, s, F3, xt, yc - 5, 2, 2 - tg, S, round, rad); rg.globalAlpha = 1; }
  }
  paintButtons(g, S, ox, yc, a, th, col, fm, kind, plain, ink, mi) {
    const L = this.L, led = col.kind === 'led', d = 20, sc = 0.85 + 0.15 * a, tg = S >= 2 ? 0.5 : 0, check = Opt.finish === 'check';
    const darkInk = mi.th === 'light';
    for (const b of [{ id: 'cancel', x: ox + L.b1 }, { id: 'stop', x: ox + L.b2 }]) {
      const hov = this.hover === b.id, prs = this.press === b.id && hov, cx = b.x + d / 2, cy = yc;
      this.btns.push({ id: b.id, x: b.x, y: cy - d / 2, w: d, h: d });
      g.save(); g.globalAlpha = a; g.translate(cx * S, cy * S); const ps = prs ? 0.93 : 1; g.scale(sc * ps, sc * ps); g.translate(-cx * S, -cy * S);
      const bp = () => shapePath(g, kind, b.x, cy - d / 2, d, d, S, d);
      if (b.id === 'cancel') {
        const full = fm === 'full';
        g.beginPath(); bp(); g.fillStyle = full ? (prs ? 'rgba(29,40,21,0.3)' : hov ? 'rgba(29,40,21,0.2)' : 'rgba(29,40,21,0.1)') : (prs ? th.btnPress : hov ? th.btnHover : th.btn); g.fill();
        g.fillStyle = full ? col.ink : th.glyph;
        if (plain) { g.strokeStyle = th.glyph; g.lineWidth = 1.7 * S; g.lineCap = 'round'; g.beginPath(); g.moveTo((cx - 3.2) * S, (cy - 3.2) * S); g.lineTo((cx + 3.2) * S, (cy + 3.2) * S); g.moveTo((cx + 3.2) * S, (cy - 3.2) * S); g.lineTo((cx - 3.2) * S, (cy + 3.2) * S); g.stroke(); }
        else bitmap(g, G.x5, cx - 5, cy - 5, 2, 2 - tg, S, this.cfg.shape === 'round', this.cfg.rad || 0);
      } else {
        const base = plain ? (darkInk ? '#1d1d1f' : '#f4f3e8') : col.ink, glyph = plain ? (darkInk ? '#ffffff' : '#1d1d1f') : (led ? '#1a1306' : col.face[0]);
        g.beginPath(); bp(); g.fillStyle = base; g.fill();
        if (hov || prs) { g.fillStyle = prs ? 'rgba(0,0,0,0.22)' : (darkInk && plain ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.20)'); g.fill(); }
        g.fillStyle = glyph;
        if (plain) {
          if (check) { g.strokeStyle = glyph; g.lineWidth = 1.9 * S; g.lineCap = 'round'; g.lineJoin = 'round'; g.beginPath(); g.moveTo((cx - 3.6) * S, (cy + 0.2) * S); g.lineTo((cx - 1.2) * S, (cy + 2.8) * S); g.lineTo((cx + 3.8) * S, (cy - 2.8) * S); g.stroke(); }
          else { g.beginPath(); g.roundRect((cx - 3.2) * S, (cy - 3.2) * S, 6.4 * S, 6.4 * S, 1.4 * S); g.fill(); }
        } else if (check) bitmap(g, G.check, cx - 7, cy - 5, 2, 2 - tg, S, this.cfg.shape === 'round', this.cfg.rad || 0);
        else { g.beginPath(); g.roundRect((cx - 4) * S, (cy - 4) * S, 8 * S, 8 * S, 1.2 * S); g.fill(); }
      }
      g.restore();
    }
    g.globalAlpha = 1;
  }

  /* ---- references ---- */
  paintClassic(g, S, ox, oy, W, H) {
    const yc = oy + H / 2, k = this.content, lines = this.L.lines;
    g.save(); g.beginPath(); shapePath(g, 'capsule', ox, oy, W, H, S, Math.min(H, 28)); g.shadowColor = 'rgba(0,0,0,0.45)'; g.shadowBlur = 12 * S; g.shadowOffsetY = 4 * S; g.fillStyle = '#1a1a1a'; g.fill(); g.restore();
    g.beginPath(); shapePath(g, 'capsule', ox + 0.5, oy + 0.5, W - 1, H - 1, S, 28); g.strokeStyle = '#4d4a42'; g.lineWidth = S; g.stroke();
    g.fillStyle = '#ffffeb';
    if (k === 'msg' || k === 'err' || k === 'record') {
      g.font = tfFont(tfSpec('classic'), S); g.textAlign = 'center'; g.fillStyle = k === 'err' ? '#ff8a80' : '#ffffeb';
      const ls = lines || [this.text], lh = this.L.lh || 16; ls.forEach((l, i) => fillTextC(g, l, ox + W / 2, yc + (i - (ls.length - 1) / 2) * lh, S)); g.textAlign = 'left'; return;
    }
    for (let i = 0; i < 10; i++) {
      let v = this.meter.v[i];
      if (k === 'proc') v = clamp(1 - Math.abs(i - (Math.sin(this.t / T.procPeriod * TAU - Math.PI / 2) * 0.5 + 0.5) * 9) / 3);
      const h = 4 + v * 16, x = (k === 'locked' ? ox + 14 : ox + 22) + i * 5.3;
      g.beginPath(); g.roundRect(x * S, (yc - h / 2) * S, 2.6 * S, h * S, 1.3 * S); g.fill();
    }
    if (k === 'locked') for (const [i, id] of ['cancel', 'stop'].entries()) {
      const bx = ox + W - 52 + i * 24, cx = bx + 10; this.btns.push({ id, x: bx, y: yc - 10, w: 20, h: 20 });
      g.beginPath(); g.arc(cx * S, yc * S, 10 * S, 0, TAU); g.fillStyle = this.hover === id ? 'rgba(255,255,235,0.22)' : 'rgba(255,255,235,0.12)'; g.fill();
      g.strokeStyle = '#ffffeb'; g.fillStyle = '#ffffeb'; g.lineWidth = 1.4 * S; g.lineCap = 'round';
      if (id === 'cancel') { g.beginPath(); g.moveTo((cx - 3) * S, (yc - 3) * S); g.lineTo((cx + 3) * S, (yc + 3) * S); g.moveTo((cx + 3) * S, (yc - 3) * S); g.lineTo((cx - 3) * S, (yc + 3) * S); g.stroke(); }
      else { g.beginPath(); g.roundRect((cx - 3) * S, (yc - 3) * S, 6 * S, 6 * S, 1.2 * S); g.fill(); }
    }
  }
  paintHifi(g, S, ox, oy) {
    const k = this.content, H = 32, W = 146;
    const R = (x, y, w, h, c) => { g.fillStyle = c; g.fillRect(Math.round((ox + x) * S), Math.round((oy + y) * S), Math.round(w * S), Math.round(h * S)); };
    g.save(); g.shadowColor = 'rgba(0,0,0,0.5)'; g.shadowBlur = 12 * S; g.shadowOffsetY = 4 * S; R(0, 0, W, H, '#111'); g.restore();
    R(0, 0, W, H, '#0a0a0b'); R(1, 1, W - 2, H - 2, '#2b2b2e'); R(1, 1, W - 2, 1, '#4a4a4f'); R(1, H - 2, W - 2, 1, '#18181a');
    for (const [x, y] of [[2, 2], [W - 4, 2], [2, H - 4], [W - 4, H - 4]]) R(x, y, 2, 2, '#0a0a0b');
    const cx = ox + 17, cy = oy + 13;
    g.beginPath(); g.arc(cx * S, cy * S, 9 * S, 0, TAU); g.fillStyle = '#0a0a0b'; g.fill();
    g.beginPath(); g.arc(cx * S, cy * S, 8 * S, 0, TAU); const bg = g.createLinearGradient(0, (cy - 8) * S, 0, (cy + 8) * S); bg.addColorStop(0, '#e2e2e2'); bg.addColorStop(1, '#85858a'); g.fillStyle = bg; g.fill();
    const on = k === 'rec' || k === 'locked';
    g.beginPath(); g.arc(cx * S, cy * S, 3 * S, 0, TAU); g.fillStyle = on ? '#ff3b30' : '#6a2a26'; g.fill();
    const lab = (s, x, y) => { g.fillStyle = '#9a9a96'; textBM(g, s, F3, ox + x, oy + y, 1, 1, S, false, 0); };
    lab('TALK', 8, 24); lab('REC', 31, 24);
    g.beginPath(); g.arc((ox + 37) * S, (oy + 9) * S, 3 * S, 0, TAU); g.fillStyle = on ? '#ff3b30' : '#4a1a18'; g.fill();
    R(48, 3, 62, 25, '#050403'); R(49, 27, 60, 1, '#3a3a3d');
    const amb = '#ffa51c', gh = 'rgba(255,165,28,0.13)';
    if (k === 'msg' || k === 'err' || k === 'record') {
      const s = (this.text || '').toUpperCase(), tw = textCols(s, F5), vw = 56;
      g.save(); g.beginPath(); g.rect((ox + 50) * S, (oy + 4) * S, vw * S, 22 * S); g.clip(); g.fillStyle = k === 'err' ? '#ff4a3c' : amb;
      const off = tw > vw ? this.scrollOffset(tw, vw) : 0;
      textBM(g, s, F5, ox + (tw > vw ? 50 : 79 - tw / 2) - off, oy + 9, 1, 1, S, false, 0); g.restore();
    } else {
      for (let i = 0; i < 16; i++) {
        let v = this.meter.v[i];
        if (k === 'proc') v = clamp(1 - Math.abs(i - (Math.sin(this.t / T.procPeriod * TAU - Math.PI / 2) * 0.5 + 0.5) * 15) / 3);
        const n = Math.round(v * 8);
        for (let r = 0; r < 8; r++) { g.fillStyle = r >= 8 - n ? amb : gh; g.fillRect(Math.round((ox + 52 + i * 2.4) * S), Math.round((oy + 7 + r * 2.4) * S), Math.round(1.6 * S), Math.round(1.6 * S)); }
      }
      const s = k === 'locked' ? this.clockStr() : '0:00'; g.fillStyle = amb; textBM(g, s, F3, ox + 92 - textCols(s, F3) / 2, oy + 8, 1, 1, S, false, 0);
    }
    for (const [i, id] of ['cancel', 'stop'].entries()) {
      const bx = 116 + i * 14; R(bx, 8, 12, 12, '#0a0a0b'); R(bx + 1, 9, 10, 10, this.hover === id ? '#c8c8c8' : '#9c9ca0'); R(bx + 1, 9, 10, 1, '#d6d6d8');
      if (id === 'cancel') { g.fillStyle = '#222'; bitmap(g, G.x5, ox + bx + 3.5, oy + 11.5, 1, 1, S, false, 0); } else R(bx + 4, 12, 4, 4, '#222');
      this.btns.push({ id, x: ox + bx, y: oy + 8, w: 12, h: 12 });
    }
    lab('CAN', 115, 24); lab('STP', 129, 24);
  }
}

/* ---------- simulated voice ---------- */
const Voice = {
  gain: 0.7, mic: false, ana: null, buf: null, level: 0, env: 0, tgt: 0, tNext: 0, syl: 0, stress: 1, t: 0, jt: 0, jit: 1,
  step(dt) {
    if (this.mic && this.ana) {
      this.ana.getFloatTimeDomainData(this.buf); let s = 0; for (const v of this.buf) s += v * v;
      this.level = clamp(Math.sqrt(Math.sqrt(s / this.buf.length)) * 2.6 * this.gain * 1.4); return this.level;
    }
    this.t += dt; this.jt += dt;
    if (this.jt > 32) { this.jt = 0; this.jit = 0.8 + Math.random() * 0.4; }
    if (this.t >= this.tNext) {
      if (this.syl <= 0) {
        if (!this.justPaused && Math.random() < 0.22) { this.tgt = 0.02; this.tNext = this.t + 280 + Math.random() * 520; this.justPaused = true; }
        else { this.justPaused = false; this.syl = 2 + Math.floor(Math.random() * 4); this.stress = 0.6 + Math.random() * 0.4; }
      }
      if (this.syl > 0) {
        this.syl--; this.tgt = (0.3 + 0.7 * Math.pow(Math.random(), 0.7)) * this.stress; this.tNext = this.t + 85 + Math.random() * 110;
        if (this.syl <= 0) this.tNext += 30 + Math.random() * 50;
      }
    }
    this.env += (this.tgt - this.env) * (this.tgt > this.env ? 1 - Math.exp(-dt / 22) : 1 - Math.exp(-dt / 70));
    this.level = clamp(this.env * this.jit * this.gain * 1.25 + Math.random() * 0.012);
    return this.level;
  },
  async enableMic() {
    try {
      const st = await navigator.mediaDevices.getUserMedia({ audio: true });
      const ac = new (window.AudioContext || window.webkitAudioContext)(); const src = ac.createMediaStreamSource(st);
      this.ana = ac.createAnalyser(); this.ana.fftSize = 1024; this.buf = new Float32Array(1024); src.connect(this.ana); this.mic = true; return true;
    } catch (e) { this.mic = false; return false; }
  },
  disableMic() { this.mic = false; },
};
