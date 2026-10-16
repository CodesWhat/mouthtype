import "./hero-demo.js";

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
document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", () => {
    document
      .querySelectorAll("[data-copy]")
      .forEach((item) =>
        item.setAttribute("aria-pressed", String(item === button)),
      );
    const text = document.querySelector("#example-text");
    if (button.dataset.copy === "clean") {
      const spelling = document.createElement("mark");
      spelling.textContent = "Sean";
      text.replaceChildren("Send the mockups to ", spelling, " before Friday.");
    } else text.textContent = examples.heard.text;
    document.querySelector("#example-note").textContent =
      examples[button.dataset.copy].note;
  });
});
