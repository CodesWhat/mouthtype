/* ---------- page controller ---------- */
const ORDER = ['classic', 'hifi', 'minimal', 'float', 'window', 'twin', 'face', 'sign'];
const MATS = [['dark', 'Solid dark'], ['light', 'Solid light'], ['glass', 'Glass'], ['smoke', 'Smoked glass'], ['all', 'Compare all four']];
const $ = (s, r = document) => r.querySelector(s);
const pills = []; let selKey = 'float'; let zoom = 2; let bgName = 'light'; let dockPill = null;
const q = new URLSearchParams(location.search);
const DPR = q.get('dpr') ? +q.get('dpr') : (window.devicePixelRatio || 1);
const PX = q.get('px') === '1';   // sheet mode: canvas px == css px

let PHOTO = null;
function applyBg() {
  Opt.bgLum = bgName === 'light' ? 0.92 : bgName === 'dark' ? 0.1 : 0.5;
  for (const el of [$('#stage'), $('#dockwrap'), $('#cardstage')]) {
    if (!el) continue; el.classList.remove('light', 'dark', 'photo'); el.classList.add(bgName); el.style.backgroundImage = '';
    if (bgName === 'photo') { PHOTO = PHOTO || photoURL(); el.style.backgroundImage = `url(${PHOTO})`; }
  }
}
function matsToShow() { return Opt.material === 'all' ? ['dark', 'light', 'glass', 'smoke'] : [Opt.material]; }
function mk(host, key) { const p = new Pill(host, key, { S: PX ? zoom : zoom * DPR, css: PX ? zoom / DPR : zoom }); p.onButton = id => onButton(id); return p; }
function buildGallery() {
  for (const p of pills) p.host.remove(); pills.length = 0; dockPill = null;
  const gal = $('#gal'); gal.innerHTML = ''; gal.style.gridTemplateColumns = `repeat(auto-fill,minmax(${CW * zoom + 16}px,1fr))`;
  const mats = matsToShow();
  for (const key of ORDER) {
    const cfg = DIRS[key] || REF[key];
    const card = document.createElement('div'); card.className = 'card' + (key === selKey ? ' sel' : ''); card.dataset.key = key;
    card.innerHTML = `<span class="nm">${cfg.name}</span><span class="bl">${cfg.blurb}</span><div class="hosts"></div>`;
    card.querySelector('.nm').onclick = () => { selKey = key; buildGallery(); buildDock(); buildPanel(); };
    const hosts = card.querySelector('.hosts');
    for (const m of (cfg.ref ? [mats[0]] : mats)) { const h = document.createElement('div'); h.className = 'pillwrap'; hosts.appendChild(h); const p = mk(h, key); p.mat = Opt.material === 'all' ? m : null; pills.push(p); if (cfg.ref && m !== mats[0]) { p.ref = true; } }
    gal.appendChild(card);
  }
  syncState();
}
function buildDock() {
  const w = $('#dockpill'); if (dockPill) { const i = pills.indexOf(dockPill); if (i >= 0) pills.splice(i, 1); }
  w.innerHTML = ''; const dh = document.createElement('div'); dh.className = 'pillwrap'; w.appendChild(dh); dockPill = mk(dh, selKey); pills.push(dockPill);
  $('#dockwrap').style.setProperty('--z', zoom); syncState();
}
let current = { content: 'rec', text: '', visible: false };
function syncState() { for (const p of pills) { if (current.visible) { p.show(current.content, current.text); p.phase = 'shown'; p.tPhase = 999; p.vis = 1; } } }

let timers = [];
const later = (ms, fn) => timers.push(setTimeout(fn, ms));
function clearTimers() { timers.forEach(clearTimeout); timers = []; }
function apply(content, text) { current.content = content; current.text = text || ''; current.visible = true; for (const p of pills) p.show(content, text); }
const cmd = {
  appear() { clearTimers(); for (const p of pills) { p.hide(); p.phase = 'hidden'; p.vis = 0; } current.visible = false; setTimeout(() => apply('rec'), 30); },
  hold() { clearTimers(); apply('rec'); },
  lock() { clearTimers(); apply('locked'); },
  proc() { clearTimers(); apply('proc'); },
  msg(t) { clearTimers(); apply('msg', t); if ($('#auto').checked) later(T.msgAutoHide + 800, () => cmd.hide()); },
  err(t) { clearTimers(); apply('err', t || 'No microphone'); },
  record() { clearTimers(); apply('record', 'New best'); if ($('#auto').checked) later(T.record + 900, () => cmd.hide()); },
  hide() { clearTimers(); current.visible = false; for (const p of pills) p.hide(); },
};
function onButton(id) {
  if (id === 'cancel') { clearTimers(); apply('msg', 'Cancelled'); later(1100, cmd.hide); }
  else { clearTimers(); apply('proc'); later(900, () => { apply('msg', 'Copied'); later(1200, cmd.hide); }); }
}

/* ---------- spec panel ---------- */
function buildPanel() {
  const p = new Pill(document.createElement('div'), selKey, { S: 1, css: 1 }); p.phase = 'shown';
  const cfg = p.cfg, rows = [];
  const add = (a, b) => rows.push(`<tr><td>${a}</td><td>${b}</td></tr>`);
  const kind = p.kind;
  add('Selected', `<b>${cfg.name}</b>, ${cfg.blurb}`);
  if (cfg.ref) { add('Size', cfg.id === 'classic' ? '97 x 28 pt (locked 137)' : '146 x 32 pt'); add('Note', 'Reference only: a faithful approximation of the shipped pill.'); }
  else {
    const Lr = p.layout('rec'), Ll = p.layout('locked');
    p.text = 'TOO SHORT'; const Lm = p.layout('msg', 'TOO SHORT');
    const H = cfg.H, rr = kind === 'capsule' ? H / 2 : kind === 'mid' ? 0.4 * H : 0.34 * H;
    add('Size (pt)', `held ${Math.round(Lr.W)} x ${H}, locked ${Math.round(Ll.W)} x ${H}, "TOO SHORT" ${Math.round(Lm.W)} x ${H}`);
    add('Silhouette', `${kind}, corner ${rr.toFixed(1)} pt` + (kind === 'squircle' ? ' (superellipse, exponent n=4, extent ' + (rr * 1.32).toFixed(1) + ' pt)' : ''));
    add('Controls', `20 x 20 pt, ${kind === 'capsule' ? 'discs' : kind === 'mid' ? 'rounded squares r=8' : 'squircles'}, 3 pt apart, 5 pt from the right edge; finish = ${Opt.finish}`);
    if (cfg.plain) add('Readout', `${cfg.cols} vector bars, ${cfg.dw} pt wide, ${cfg.px} pt pitch, rounded caps, centre-mirrored (${cfg.rows} rows of ${cfg.py} pt). Text is the system face: REC 9.5 px/600, clock 12 px/500 tabular, message 13 px/600.`);
    else add('Readout', `${cfg.cols} x ${cfg.rows} ${cfg.mode} dot grid, dot ${cfg.dw} x ${cfg.dh} pt (${cfg.shape === 'round' ? 'round' : 'soft square'}), pitch ${cfg.px} x ${cfg.py} pt. Text 5x7 (14 pt caps) and 3x5 (10 pt) at 2 pt pitch; clock ${cfg.timeStyle === 'seg' ? '7-segment 6 x 11 pt, ghost 8s' : '3x5 dot matrix'}.`);
    const col = p.col, th = THEMES[p.mi.th];
    add('Colour', `${col.name}: ink ${col.ink}, REC ${col.rec}, error ${col.err}, ghost alpha ${col.ghost}${col.glow ? ', glow ' + col.glow + ' ' + cfg.glowPt + ' pt' : ''}`);
    add('Chrome', `body ${th.body[0]} to ${th.body[1]}, hairline ${th.stroke}, shadow y4 blur12 + contact y0.8 blur2`);
  }
  add('Material', Opt.material === 'all' ? 'comparing all four' : (MATS.find(m => m[0] === Opt.material) || [])[1]);
  const note = (Opt.material === 'glass' || Opt.material === 'smoke' || Opt.material === 'all') ? '<div class="note">Glass here is a CSS approximation of macOS 26 Liquid Glass: backdrop blur + saturation, a specular rim brighter at the top-left, a soft bottom inner shadow. It does not refract or lens the edge. The shipping app would use the system glass material (NSGlassEffectView) on macOS 26 and fall back to the solid body elsewhere.</div>' : '';
  $('#panel').innerHTML = '<h3>Spec</h3><table>' + rows.join('') + '</table>' + note;
}

/* ---------- controls ---------- */
function btnRow(el, items, onclick, active) {
  el.innerHTML = ''; for (const [v, label] of items) { const b = document.createElement('button'); b.textContent = label; b.dataset.v = v; if (v === active) b.classList.add('on'); b.onclick = () => { onclick(v); [...el.children].forEach(c => c.classList.toggle('on', c.dataset.v === v)); }; el.appendChild(b); }
}
function init() {
  btnRow($('#zoom'), [['1', '1x'], ['2', '2x'], ['4', '4x']], v => { zoom = +v; rebuild(); }, String(zoom));
  btnRow($('#bg'), [['light', 'Light window'], ['dark', 'Dark window'], ['photo', 'Busy photo']], v => { bgName = v; applyBg(); buildPanel(); }, bgName);
  btnRow($('#shape'), [['default', 'As designed'], ['capsule', 'Capsule'], ['mid', 'In-between'], ['squircle', 'Squircle']], v => { Opt.shape = v; buildPanel(); }, Opt.shape);
  btnRow($('#mat'), MATS, v => { Opt.material = v; rebuild(); }, Opt.material);
  btnRow($('#col'), [['', 'As designed'], ['lcd', 'Pager LCD'], ['amber', 'Amber'], ['red', 'Red'], ['white', 'Cool white']], v => { Opt.color = v || null; buildPanel(); }, '');
  btnRow($('#lab'), [['dots', 'Dot matrix'], ['pixel', 'Solid pixel'], ['seg', '14-segment'], ['rounded', 'Rounded sans'], ['sans', 'System sans'], ['jbm', 'JetBrains Mono']], v => { Opt.label = v; if (cardCase) cardRender('noanim'); buildPanel(); }, Opt.label);
  btnRow($('#cbtn'), [['calm', 'Calm'], ['amber', 'Amber']], v => { Opt.cardBtn = v; for (const o of cardFrames) o.sig = ''; }, Opt.cardBtn);
  const tl = $('#tflist');
  { const b = document.createElement('button'); b.className = 'preset'; b.dataset.v = 'systema'; b.textContent = 'Systema set: serif headers, sans body, mono data'; b.onclick = () => { Opt.tf.preset = 'systema'; Opt.tf.custom = ''; $('#tfany').value = ''; tfApply(); }; tl.appendChild(b); }
  for (const [k, name, stack, fl] of TF_OPTS) { const b = document.createElement('button'); b.textContent = name; b.dataset.v = k; b.style.fontFamily = stack; if (fl.inst) b.dataset.inst = fl.inst; b.onclick = () => { Opt.tf.family = k; Opt.tf.preset = ''; Opt.tf.custom = ''; $('#tfany').value = ''; tfApply(); }; tl.appendChild(b); }
  $('#tfany').value = Opt.tf.custom || ''; $('#tfany').oninput = e => { Opt.tf.custom = e.target.value; tfApply(); };
  btnRow($('#tfw'), [['400', 'Regular'], ['500', 'Medium'], ['600', 'Semibold']], v => { Opt.tf.weight = +v; tfApply(); }, String(Opt.tf.weight));
  btnRow($('#tfs'), [['-1', '-1 pt'], ['0', '0'], ['1', '+1 pt']], v => { Opt.tf.size = +v; tfApply(); }, String(Opt.tf.size));
  tfApply(true); const reTF = () => { _instCache = {}; _pmKey = ''; tfApply(true); };
  if (document.fonts) { Promise.all(EMBED_LOADS.map(f => document.fonts.load(f))).then(reTF).catch(reTF); document.fonts.ready.then(reTF); }
  btnRow($('#fin'), [['stop', 'Stop square'], ['check', 'Check mark']], v => { Opt.finish = v; buildPanel(); }, Opt.finish);
  btnRow($('#long'), [['grow', 'Grow taller'], ['scroll', 'Scroll']], v => { Opt.long = v; }, 'grow');
  Opt.long = 'grow';
  const A = $('#acts'); const mkb = (t, f) => { const b = document.createElement('button'); b.textContent = t; b.onclick = f; A.appendChild(b); };
  mkb('Appear', cmd.appear); mkb('Hold', cmd.hold); mkb('Locked', cmd.lock); mkb('Processing', cmd.proc); mkb('New record', cmd.record); mkb('Error', () => cmd.err('No microphone')); mkb('Hide', cmd.hide);
  const P = $('#pre'); const mkp = (t, f) => { const b = document.createElement('button'); b.textContent = t; b.onclick = f; P.appendChild(b); };
  mkp('Too short', () => cmd.msg('Too short')); mkp('Copied', () => cmd.msg('Copied')); mkp('Cancelled', () => cmd.msg('Cancelled'));
  mkp('Long message', () => cmd.msg('Microphone disconnected, 14 seconds saved to history'));
  $('#send').onclick = () => cmd.msg($('#txt').value || 'Hello');
  $('#lvl').oninput = e => { Voice.gain = +e.target.value / 100; };
  $('#mic').onclick = async () => { const b = $('#mic'); if (Voice.mic) { Voice.disableMic(); b.textContent = 'Use microphone'; b.classList.remove('on'); return; } const ok = await Voice.enableMic(); b.textContent = ok ? 'Microphone on (click to stop)' : 'Use microphone (blocked, simulating)'; b.classList.toggle('on', ok); };
  $('#dockchk').onchange = e => { $('#dockwrap').style.display = e.target.checked ? '' : 'none'; };
  const C = $('#cardbtns'); for (const k in CARD_CASES) { const b = document.createElement('button'); b.textContent = CARD_CASES[k].label; b.onclick = () => showCard(k); C.appendChild(b); }
  const lb = document.createElement('button'); lb.textContent = 'Long transcript'; lb.onclick = () => { cardLong = !cardLong; lb.classList.toggle('on', cardLong); if (cardCase) cardRender('noanim'); }; C.appendChild(lb);
  const hb = document.createElement('button'); hb.textContent = 'Dismiss card'; hb.onclick = cardDismiss; C.appendChild(hb);
  applyBg(); rebuild();
}
function tfApply(noSave) {
  if (!noSave) saveTF();
  for (const b of $('#tflist').children) { b.classList.toggle('on', !Opt.tf.custom && (Opt.tf.preset === 'systema' ? b.dataset.v === 'systema' : b.dataset.v === Opt.tf.family)); if (b.dataset.inst) b.classList.toggle('dim', !fontInstalled(b.dataset.inst)); }
  const c = (Opt.tf.custom || '').trim(); $('#tfnote').textContent = c && !fontInstalled(c) ? `"${c}" is not installed, using the system font.` : '';
  for (const p of pills) { p._tmKey = null; p._tm = null; }
  for (const o of cardFrames) o.sig = '';
}
function rebuild() { buildGallery(); buildCards(); buildDock(); buildPanel(); $('#dockwrap').style.setProperty('--z', zoom); }
let last = performance.now();
function frame(now) {
  const dt = Math.min(50, now - last); last = now; const lv = Voice.step(dt);
  for (const p of pills) { p.step(dt, lv); p.render(); }
  cardTick();
  requestAnimationFrame(frame);
}
window.addEventListener('DOMContentLoaded', () => { if (q.get('sheet')) return; init(); requestAnimationFrame(frame); setTimeout(() => cmd.hold(), 150); });
