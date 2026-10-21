import "./hero-demo.js";
import "./menubar-mouth.js";
import "./wpm.js";

const principles = document.querySelector(".principles-group");
const repeatedPrinciples = principles.cloneNode(true);
repeatedPrinciples.setAttribute("aria-hidden", "true");
repeatedPrinciples.inert = true;
principles.parentElement.append(repeatedPrinciples);

const stage = document.querySelector(".object-stage");
const preview = document.querySelector("#pill-preview");
const description = document.querySelector(".product-preview");
document.querySelectorAll('input[name="skin"]').forEach((input) => {
  input.addEventListener("change", () => {
    const classic = input.value === "classic";
    const name = classic ? "Classic" : "Hi-Fi";
    stage.dataset.skin = input.value;
    preview.src = classic
      ? "/assets/classic-recording.png"
      : "/assets/hifi-recording.png";
    preview.width = classic ? 416 : 584;
    preview.height = classic ? 112 : 128;
    preview.alt = `Mouthtype ${name} recording pill`;
    description.setAttribute(
      "aria-label",
      `Speaking and typing illustration with the ${name} Mouthtype pill`,
    );
  });
});

const headlines = [
  {
    tagline: "SOFTWARE FOR SAYING THINGS",
    first: "Words, straight",
    second: "from the ",
    emphasis: "source.",
  },
  {
    tagline: "FROM YOUR HEAD. THROUGH YOUR MOUTH.",
    first: "Say it.",
    second: "Keep ",
    emphasis: "moving.",
  },
];
const headline = headlines[Math.floor(Math.random() * headlines.length)];
const emphasis = document.createElement("em");
emphasis.textContent = headline.emphasis;
document
  .querySelector("#hero-title")
  .replaceChildren(
    headline.first,
    document.createElement("br"),
    headline.second,
    emphasis,
  );
document.querySelector("#hero-tagline").textContent = headline.tagline;

const examples = {
  heard: {
    text: "um send the mockups to shawn before friday",
    note: "Prepared example · “Shawn” → “Sean” is a saved spelling.",
  },
  clean: {
    text: "Send the mockups to Sean before Friday.",
    note: "Filler removed. Punctuation added. Saved spelling applied.",
  },
};
const card = document.querySelector("#demo .example");
const exampleText = document.querySelector("#example-text");
const exampleNote = document.querySelector("#example-note");
const exampleLive = document.querySelector("#example-live");
const copyButtons = document.querySelectorAll("[data-copy]");
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
const fadeMs = 350;
const cycleMs = 6000;
let current = "clean";
let swapTimer;
let cycleTimer;
let stopped = false;
let cardVisible = false;

function paint(key) {
  copyButtons.forEach((item) =>
    item.setAttribute("aria-pressed", String(item.dataset.copy === key)),
  );
  if (key === "clean") {
    const spelling = document.createElement("mark");
    spelling.textContent = "Sean";
    exampleText.replaceChildren("Send the mockups to ", spelling, " before Friday.");
  } else exampleText.textContent = examples.heard.text;
  exampleNote.lastChild.textContent = examples[key].note;
}

function show(key, { announce = false } = {}) {
  clearTimeout(swapTimer);
  current = key;
  if (reduceMotion.matches) {
    paint(key);
  } else {
    exampleText.classList.add("is-fading");
    swapTimer = setTimeout(() => {
      paint(key);
      exampleText.classList.remove("is-fading");
    }, fadeMs);
  }
  if (announce) exampleLive.textContent = `${examples[key].label}: ${examples[key].text}`;
}

function syncCycle() {
  const run =
    !stopped && cardVisible && !document.hidden && !reduceMotion.matches;
  if (run && !cycleTimer) {
    cycleTimer = setInterval(
      () => show(current === "clean" ? "heard" : "clean"),
      cycleMs,
    );
  } else if (!run && cycleTimer) {
    clearInterval(cycleTimer);
    cycleTimer = undefined;
  }
}

function stopCycling() {
  stopped = true;
  syncCycle();
}

examples.heard.label = "As spoken";
examples.clean.label = "Cleaned up";
copyButtons.forEach((button) => {
  button.addEventListener("click", () => {
    stopCycling();
    show(button.dataset.copy, { announce: true });
  });
});
["pointerenter", "pointerdown", "focusin"].forEach((type) =>
  card.addEventListener(type, stopCycling),
);
document.addEventListener("visibilitychange", syncCycle);
reduceMotion.addEventListener("change", syncCycle);
new IntersectionObserver(
  ([entry]) => {
    cardVisible = entry.isIntersecting;
    syncCycle();
  },
  { threshold: 0.4 },
).observe(card);
