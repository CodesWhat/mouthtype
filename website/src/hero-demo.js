import { SPEAKING_WPM, TYPING_WPM } from "./wpm-constants.js";

const preview = document.querySelector(".product-preview");
const voice = document.querySelector("#voice-copy");
const typing = document.querySelector("#typing-copy");
const phrases = [
  "I'll send the first draft before lunch.",
  "Let's move our meeting to Friday.",
  "The blue notebook is on my desk.",
];
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const spokenWordMs = 60000 / SPEAKING_WPM;
const typedCharacterMs = 60000 / (TYPING_WPM * 5);
let frame;
let visible = false;
let suspended = false;
let example = 0;

function render(phrase, elapsed) {
  const words = phrase.split(" ");
  const spokenCount = Math.min(words.length, Math.floor(elapsed / spokenWordMs));
  const typedCount = Math.min(phrase.length, Math.floor(elapsed / typedCharacterMs));
  voice.textContent = words.slice(0, spokenCount).join(" ");
  typing.textContent = phrase.slice(0, typedCount);
  voice.closest(".pace-lane").dataset.complete = String(spokenCount === words.length);
  typing.closest(".pace-lane").dataset.complete = String(typedCount === phrase.length);
}

function pause() {
  cancelAnimationFrame(frame);
  frame = undefined;
}

function finish() {
  pause();
  render(phrases[example], Infinity);
  preview.dataset.demo = "complete";
}

function start() {
  if (frame !== undefined || !visible || suspended || document.hidden) return;
  if (reducedMotion.matches) { finish(); return; }
  let beginning = performance.now();
  preview.dataset.demo = "running";
  function draw(now) {
    let elapsed = Math.max(0, now - beginning - 250);
    if (elapsed >= phrases[example].length * typedCharacterMs + 2200) {
      example = (example + 1) % phrases.length;
      beginning = now;
      elapsed = 0;
    }
    render(phrases[example], elapsed);
    frame = requestAnimationFrame(draw);
  }
  frame = requestAnimationFrame(draw);
}

const observer = new IntersectionObserver((entries) => {
  visible = entries.some((entry) => entry.isIntersecting);
  if (visible) start(); else pause();
}, { threshold: 0.4 });

if (reducedMotion.matches) finish();
else { voice.textContent = ""; typing.textContent = ""; }
observer.observe(preview);
reducedMotion.addEventListener("change", () => {
  if (reducedMotion.matches) finish(); else start();
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) pause(); else start();
});
window.addEventListener("pagehide", () => {
  suspended = true;
  observer.disconnect();
  pause();
});
window.addEventListener("pageshow", () => {
  suspended = false;
  observer.observe(preview);
  start();
});
