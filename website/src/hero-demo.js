const preview = document.querySelector(".product-preview");
const voice = document.querySelector("#voice-copy");
const typing = document.querySelector("#typing-copy");
const phrase = "I'll send the first draft before lunch.";
const words = phrase.split(" ");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
let frame;
let started = false;
let observer;

function finish() {
  cancelAnimationFrame(frame);
  voice.textContent = phrase;
  typing.textContent = phrase;
  voice.closest(".pace-lane").dataset.complete = "true";
  typing.closest(".pace-lane").dataset.complete = "true";
  preview.dataset.demo = "complete";
}

function start() {
  if (started) return;
  started = true;
  if (reducedMotion.matches) {
    finish();
    return;
  }
  const beginning = performance.now();
  preview.dataset.demo = "running";
  function draw(now) {
    const elapsed = Math.max(0, now - beginning - 250);
    const spokenCount = Math.min(words.length, Math.floor(elapsed / 190));
    const typedCount = Math.min(phrase.length, Math.floor(elapsed / 95));
    voice.textContent = words.slice(0, spokenCount).join(" ");
    typing.textContent = phrase.slice(0, typedCount);
    voice.closest(".pace-lane").dataset.complete = String(
      spokenCount === words.length,
    );
    if (typedCount === phrase.length) {
      finish();
      return;
    }
    frame = requestAnimationFrame(draw);
  }
  frame = requestAnimationFrame(draw);
}

if (reducedMotion.matches) {
  started = true;
  finish();
} else {
  voice.textContent = "";
  typing.textContent = "";
  observer = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer.disconnect();
        start();
      }
    },
    { threshold: 0.4 },
  );
  observer.observe(preview);
}
reducedMotion.addEventListener("change", () => {
  if (reducedMotion.matches) finish();
});
window.addEventListener("pagehide", () => {
  observer?.disconnect();
  if (started) finish();
});
window.addEventListener("pageshow", () => {
  if (!started) observer?.observe(preview);
});
