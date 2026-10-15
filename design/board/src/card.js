/* ---------- delivery card: appears above the pill when text could not be delivered ---------- */
const CARD_M = 16, CARD_W = 224;
const TRANSCRIPT = 'Can you move the standup to three thirty and send Priya the updated agenda before the end of the day, thanks.';
const TRANSCRIPT_LONG = TRANSCRIPT + ' Also remind everyone that the quarterly numbers are due Friday, and ask Marcus whether the vendor call is still on for Monday morning. If it is not, push the review to Tuesday and tell the team. One more thing, the budget sheet needs the new line items before it goes out.';
const CARD_CASES = {
  paste:   { label: 'Paste failed', short: 'PASTE FAILED', pill: ['err', 'Paste failed'], reason: "Couldn't paste. Your text is safe.", acts: ['copy'] },
  nofield: { label: 'No field focused', short: 'NO FIELD', pill: ['msg', 'No field'], reason: 'No text field was focused.', acts: ['copy'] },
  secure:  { label: 'Secure field', short: 'SECURE FIELD', pill: ['msg', 'Secure field'], reason: 'Secure field, so nothing was pasted.', acts: ['copy'] },
  undo:    { label: 'Cancelled (Undo)', short: 'CANCELLED', pill: ['msg', 'Cancelled'], reason: 'Dictation cancelled.', acts: ['undo'], timed: 5000 },
  recover: { label: 'Recovered', short: 'RECOVERED', pill: ['msg', 'Recovered'], reason: 'Recovered a dictation.', acts: ['insert', 'copy'] },
};
const cardFrames = []; let cardCase = null, cardLong = false, cardT0 = 0, cardBusy = false;

function buildCards() {
  const root = $('#cardrow'); root.innerHTML = ''; cardFrames.length = 0;
  root.style.gridTemplateColumns = `repeat(auto-fill,minmax(${(CARD_W + 2 * CARD_M) * zoom + 8}px,1fr))`;
  const mats = matsToShow();
  for (const flavor of ['led', 'plain']) for (const m of mats) {
    const fr = document.createElement('div'); fr.className = 'cframe';
    fr.innerHTML = `<div class="ctitle">${flavor === 'led' ? 'LED readout default (2)' : 'Minimal'}</div><div class="cwrap"><div class="dcard"><div class="gbk"></div><canvas class="chrome"></canvas><div class="face"><div class="hdr"><span class="rdot"></span><span class="rsn"></span><button class="x" aria-label="Dismiss"></button></div><div class="sub"></div><div class="tr"></div><div class="btns"></div><div class="bar"><i></i></div></div></div></div><div class="phost"><div class="pillwrap"></div></div>`;
    root.appendChild(fr);
    const o = { fr, flavor, mat: Opt.material === 'all' ? m : null, dc: fr.querySelector('.dcard'), cw: fr.querySelector('.cwrap'), face: fr.querySelector('.face'), cv: fr.querySelector('canvas.chrome'), gbk: fr.querySelector('.gbk'), sig: '', shown: false, copied: false };
    o.pill = mk(fr.querySelector('.pillwrap'), flavor === 'led' ? 'float' : 'minimal'); o.pill.mat = o.mat; pills.push(o.pill);
    o.pill.onButton = () => {};
    fr.querySelector('.x').onclick = () => cardDismiss();
    cardFrames.push(o);
  }
  if (cardCase) cardRender(true);
}
function cardRender(first) {
  const cs = CARD_CASES[cardCase], tx = cardLong ? TRANSCRIPT_LONG : TRANSCRIPT;
  for (const o of cardFrames) {
    o.copied = false; cardLabels(o, cs); o.face.querySelector('.tr').textContent = tx; o.face.querySelector('.tr').scrollTop = 0;
    const b = o.face.querySelector('.btns'); b.innerHTML = '';
    for (const a of cs.acts) {
      const el = document.createElement('button'); el.className = 'cb ' + (a === cs.acts[0] ? 'pri' : 'sec'); el.dataset.act = a;
      el.textContent = a === 'copy' ? 'Copy' : a === 'insert' ? 'Insert' : 'Undo'; el.onclick = () => cardAct(a, o); b.appendChild(el);
    }
    o.face.querySelector('.bar').style.display = cs.timed ? '' : 'none';
    o.sig = '';
    if (first !== 'noanim') { o.dc.classList.remove('in'); o.shown = false; requestAnimationFrame(() => requestAnimationFrame(() => { o.dc.classList.add('in'); o.shown = true; })); }
  }
}
function showCard(key) {
  clearTimers(); cardCase = key; cardBusy = false; cardT0 = performance.now(); cardRender();
  const cs = CARD_CASES[key];
  for (const o of cardFrames) o.pill.show(cs.pill[0], cs.pill[1]);
}
function cardDismiss() {
  if (!cardCase) return; cardCase = null;
  for (const o of cardFrames) { o.dc.classList.remove('in'); o.shown = false; o.pill.hide(); }
}
async function cardAct(a, src) {
  if (cardBusy) return; cardBusy = true;
  const tx = cardLong ? TRANSCRIPT_LONG : TRANSCRIPT;
  if (a === 'copy') { try { await navigator.clipboard.writeText(tx); } catch (e) { try { const t = document.createElement('textarea'); t.value = tx; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove(); } catch (e2) {} } }
  for (const o of cardFrames) { const b = o.face.querySelector(`[data-act="${a}"]`); if (b) { b.textContent = a === 'copy' ? '✓ Copied' : a === 'insert' ? '✓ Inserted' : '✓ Restored'; b.classList.add('done'); } o.face.querySelector('.bar').style.display = 'none'; }
  for (const o of cardFrames) o.pill.show('msg', a === 'copy' ? 'Copied' : a === 'insert' ? 'Inserted' : 'Restored');
  cardT0 = Infinity; setTimeout(() => { cardBusy = false; cardDismiss(); }, 900);
}
function cardTick() {
  const cs = cardCase && CARD_CASES[cardCase];
  if (cs && cs.timed && cardT0 !== Infinity && !cardBusy) {
    const rem = cs.timed - (performance.now() - cardT0);
    if (rem <= 0) { cardDismiss(); }
    else for (const o of cardFrames) { const b = o.face.querySelector('[data-act="undo"]'); if (b && !b.classList.contains('done')) b.innerHTML = 'Undo <span class="num">' + Math.ceil(rem / 1000) + 's</span>'; o.face.querySelector('.bar i').style.width = (rem / cs.timed * 100) + '%'; }
  }
  for (const o of cardFrames) cardChrome(o);
}
function cardChrome(o) {
  const mi = matInfo(o.mat || Opt.material, Opt.bgLum), kind = Opt.shape === 'default' ? 'capsule' : Opt.shape, col = COLORS[Opt.color || 'amber'];
  const fw = o.face.offsetWidth, fh = o.face.offsetHeight, sig = [tfKey(), fw, fh, mi.th, mi.glass, mi.smoke, kind, o.flavor, col.ink, Opt.color, Opt.bgLum, zoom, PX].join('|');
  if (sig === o.sig) return; o.sig = sig;
  const W = fw + 2 * CARD_M, Hh = fh + 2 * CARD_M, S = (PX ? zoom : zoom * DPR);
  o.cv.style.width = W + 'px'; o.cv.style.height = Hh + 'px'; o.cv.width = Math.ceil(W * S); o.cv.height = Math.ceil(Hh * S);
  // chrome painter assumes the global CW/CH canvas for its inner-shadow overscan; fine for a smaller canvas
  const g = o.cv.getContext('2d'); g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, o.cv.width, o.cv.height);
  paintChrome(g, S, { x: CARD_M, y: CARD_M, w: fw, h: fh, hr: 30, kind, mi, fm: 'none', col });
  const pts = shapePoly(kind, 0, 0, fw, fh, 30), d = 'M' + pts.map(p => p[0].toFixed(2) + ' ' + p[1].toFixed(2)).join('L') + 'Z', s = o.gbk.style;
  if (mi.glass) {
    const bf = mi.smoke ? 'blur(20px) saturate(1.5) brightness(0.78)' : `blur(16px) saturate(1.9) brightness(${Opt.bgLum > 0.5 ? 1.05 : 1.14})`;
    s.display = 'block'; s.left = CARD_M + 'px'; s.top = CARD_M + 'px'; s.width = fw + 'px'; s.height = fh + 'px'; s.clipPath = `path('${d}')`; s.backdropFilter = bf; s.webkitBackdropFilter = bf;
  } else s.display = 'none';
  const dc = o.dc; dc.className = 'dcard ' + o.flavor + ' th-' + mi.th + ' k-' + kind + (o.shown ? ' in' : '');
  dc.style.setProperty('--ink', o.flavor === 'led' ? col.ink : (mi.th === 'light' ? '#1d1d1f' : '#f4f3e8'));
  dc.style.setProperty('--on-ink', o.flavor === 'led' ? '#1a1306' : (mi.th === 'light' ? '#fff' : '#1d1d1f'));
  dc.style.setProperty('--warn', o.flavor === 'led' ? col.ink : col.rec);
  dc.classList.add('btn-' + (o.flavor === 'led' ? Opt.cardBtn : 'calm'));
  o.face.style.clipPath = ''; // face itself is transparent; chrome is the canvas
  o.cw.style.width = ((fw + 2 * CARD_M) * zoom) + 'px'; o.cw.style.height = ((fh + 2 * CARD_M) * zoom) + 'px';
  const sys = Opt.tf.preset === 'systema';
  dc.style.setProperty('--tf', tfStack()); dc.style.setProperty('--tw', tfWeight()); dc.style.setProperty('--ts', Opt.tf.size + 'px');
  dc.style.setProperty('--tfh', sys ? F_SERIF : tfStack()); dc.style.setProperty('--twh', sys ? 400 : tfWeight()); dc.style.setProperty('--tfhs', sys ? '3px' : '0px');
  dc.style.setProperty('--tfn', sys ? F_MONO : tfStack());
  dc.style.transform = `scale(${zoom})`;
  o.fr.querySelector('.phost').style.marginTop = (-(CARD_M + 29 - 8) * zoom) + 'px';
  o.fr.querySelector('.phost').style.height = ((CH - 29) * zoom) + 'px';
  const bk = (2 + 0) ; // radius of controls follows the shape family
  const rad = kind === 'capsule' ? 13 : kind === 'mid' ? 10 : 8;
  dc.style.setProperty('--brad', rad + 'px'); dc.style.setProperty('--trad', (kind === 'capsule' ? 14 : kind === 'mid' ? 11 : 10) + 'px');
  dc.style.setProperty('--xrad', kind === 'capsule' ? '50%' : kind === 'mid' ? '7px' : '6px');
}

/* header label: LED-style card sets its status strip in the chosen label face; everything else stays system */
function cardLabels(o, cs) {
  const rsn = o.face.querySelector('.rsn'), sub = o.face.querySelector('.sub'), led = o.flavor === 'led', mode = led ? Opt.label : 'sans';
  rsn.innerHTML = ''; rsn.className = 'rsn ' + mode; sub.style.display = 'none';
  if (!led || mode === 'sans' || mode === 'rounded' || mode === 'jbm') { rsn.textContent = cs.reason; return; }
  const S = PX ? zoom : zoom * DPR, col = COLORS[Opt.color || 'amber'], ink = col.kind === 'lcd' ? '#e8e6d8' : col.ink;
  const str = cs.short, dots = mode === 'dots', seg = mode === 'seg';
  const wpt = seg ? str.length * 11 - 3 : textCols(str, F5) * 2, hpt = seg ? 12 : 14, chipPad = 7;
  const chip = document.createElement('span'); chip.className = 'chip'; const cv = document.createElement('canvas');
  const cw = wpt + 6, ch = hpt + 6;
  cv.width = Math.ceil(cw * S); cv.height = Math.ceil(ch * S); cv.style.width = cw + 'px'; cv.style.height = ch + 'px'; cv.style.display = 'block';
  const g = cv.getContext('2d'), tg = S >= 2 ? 0.5 : 0;
  if (seg) { seg14Text(g, str, 3, 3, 12, 11, S, ink, 1, col.ghost * 1.2); }
  else {
    g.fillStyle = ink; g.shadowColor = dots ? (col.glow || ink) : 'transparent'; g.shadowBlur = dots ? 3 * S : 0;
    let x = 3;
    for (const chh of str) {
      const gl = F5[chh] || F5['?'];
      if (dots) { g.save(); g.shadowBlur = 0; g.globalAlpha = col.ghost * 1.1; for (let r = 0; r < 7; r++) for (let k = 0; k < gl[0].length; k++) if (gl[r][k] !== '#') cell(g, x + k * 2, 3 + r * 2, 2 - tg, 2 - tg, S, true, 0); g.restore(); }
      for (let r = 0; r < 7; r++) for (let k = 0; k < gl[0].length; k++) if (gl[r][k] === '#') cell(g, x + k * 2, 3 + r * 2, dots ? 2 - tg : 2, dots ? 2 - tg : 2, S, dots, 0);
      x += (gl[0].length + 1) * 2;
    }
  }
  chip.appendChild(cv); rsn.appendChild(chip); sub.textContent = cs.reason; sub.style.display = 'block';
}
