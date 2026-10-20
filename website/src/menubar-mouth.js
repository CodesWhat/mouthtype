const mouth = document.querySelector(".menubar-mouth");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
// The app swaps recording frames at most 15 times a second, driven by the mic level.
const frameMs = 1000 / 15;
// Frames: 0 idle, 1 closed, 2 half, 3 wide. A phrase is a rough mic level per tick.
const phrase = [
  1, 2, 3, 2, 1, 1, 2, 3, 3, 2, 1, 2, 3, 2, 2, 1, 1, 2, 3, 2, 1, 2, 3, 3,
  2, 1, 1, 2, 2, 3, 2, 1, 2, 3, 2, 1, 1, 2, 3, 2, 1, 1, 2, 3, 3, 2, 1, 2,
];
const idleTicks = 24;
let timer;
let tick = 0;

function show(frame) {
  mouth.dataset.frame = String(frame);
}

function step() {
  const position = tick % (phrase.length + idleTicks);
  show(position < phrase.length ? phrase[position] : 0);
  tick += 1;
}

function stop() {
  clearInterval(timer);
  timer = undefined;
}

function start() {
  if (timer !== undefined || document.hidden) return;
  if (reducedMotion.matches) { show(0); return; }
  timer = setInterval(step, frameMs);
}

function sync() {
  stop();
  if (reducedMotion.matches) show(0); else start();
}

if (mouth) {
  show(0);
  sync();
  reducedMotion.addEventListener("change", sync);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop(); else start();
  });
}
