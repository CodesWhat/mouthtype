import {
  DAILY_WRITING_MINUTES,
  ELITE_TYPIST_WPM,
  FOUNDER_AVERAGE_WPM,
  FOUNDER_BEST_WPM,
  FOUNDER_TAKES,
  PROS_SCALE_WPM,
  SPEAKING_WPM,
  TYPING_WPM,
} from "./wpm-constants.js";
import {
  accuracy,
  countWords,
  grossWpm,
  isPlausible,
  minutesSaved,
  netWpm,
  speakingWpm,
  speedup,
} from "./wpm-math.js";

const card = document.querySelector("#wpm-card");

if (card) {
  const SENTENCES = [
    "I finished the draft and will send it over before lunch, so take a look when you have a minute and let me know what you think.",
    "Thanks for the update on the schedule, I moved our meeting to Friday afternoon so everyone has time to read the notes beforehand.",
    "The blue notebook is on my desk next to the window, and the spare charger is in the top drawer if you need to borrow it.",
    "Please send the mockups to the team before Friday, and let them know I will review every comment once the first round is done.",
    "We should walk through the plan together tomorrow morning, because a few of the details changed and I want to be sure we agree.",
  ];
  const TRY_AGAIN = "That didn't look right. Try again.";

  const $ = (id) => card.querySelector(`#${id}`);
  const main = $("wpm-main");
  const pros = $("wpm-pros");
  const stepLabel = $("wpm-step-label");
  const stepButtons = [...card.querySelectorAll("[data-step]")];
  const panels = {
    type: $("wpm-type-panel"),
    speak: $("wpm-speak-panel"),
    result: $("wpm-result-panel"),
  };
  const labels = {
    type: "Step 1 of 3 · Typing",
    speak: "Step 2 of 3 · Speaking",
    result: "Step 3 of 3 · Your result",
  };
  const sentenceEl = $("wpm-sentence");
  const input = $("wpm-input");
  const typeStart = $("wpm-type-start");
  const typeCountdown = $("wpm-type-countdown");
  const hint = $("wpm-hint");
  const typeLive = $("wpm-type-live");
  const typeStats = $("wpm-type-stats");
  const speakSentence = $("wpm-speak-sentence");
  const speakButton = $("wpm-speak-button");
  const speakNote = $("wpm-speak-note");
  const speakLive = $("wpm-speak-live");
  const speakStats = $("wpm-speak-stats");
  const live = $("wpm-live");

  const typeHintText = hint.innerHTML;
  const typePlaceholder = input.placeholder;
  let target = "";
  let step = "type";
  let typed = null; // { wpm, accuracy }
  let spoken = null; // { wpm }

  // Typing run state.
  let prev = "";
  let startedAt = null;
  let keystrokes = 0;
  let misses = 0;
  let typingDone = false;
  let typingReady = false;
  let countdownTimer;
  let typeTimer;

  // Speaking run state.
  let speakStart = null;
  let speakTimer;

  const now = () => performance.now();
  const announce = (text) => {
    live.textContent = text;
  };

  function pickSentence(avoid) {
    const choices = SENTENCES.filter((s) => s !== avoid);
    return choices[Math.floor(Math.random() * choices.length)];
  }

  function renderSentence(value) {
    const frag = document.createDocumentFragment();
    const length = Math.max(target.length, value.length);
    for (let i = 0; i < length; i += 1) {
      const span = document.createElement("i");
      if (i < value.length) {
        const ch = value[i];
        span.textContent = ch === " " ? " " : ch;
        if (i < target.length && ch === target[i]) span.dataset.ok = "";
        else span.dataset.bad = "";
      } else {
        span.textContent = target[i];
        if (i === value.length && typingReady && !typingDone) span.dataset.next = "";
      }
      frag.append(span);
    }
    sentenceEl.replaceChildren(frag);
  }

  function setTarget(sentence) {
    target = sentence;
    sentenceEl.dataset.target = sentence;
    speakSentence.textContent = sentence;
    renderSentence("");
  }

  function setStep(next) {
    if (next !== "type" && countdownTimer !== undefined) resetTyping();
    step = next;
    for (const [name, panel] of Object.entries(panels)) panel.hidden = name !== next;
    for (const button of stepButtons) {
      button.setAttribute("aria-pressed", String(button.dataset.step === next));
    }
    stepButtons.find((b) => b.dataset.step === "result").disabled = !(typed && spoken);
    stepLabel.textContent = labels[next];
  }

  function focusStep(next) {
    if (next === "type") {
      if (typingReady && !typingDone) input.focus();
      else if (!typingDone) typeStart.focus();
    } else if (next === "speak") speakButton.focus();
    else {
      const body = panels.result.querySelector(".wpm-a-result");
      body.tabIndex = -1;
      body.focus();
    }
  }

  function go(next, { focus = false } = {}) {
    setStep(next);
    if (focus) focusStep(next);
  }

  /* Typing */

  function missLabel() {
    return misses === 1 ? "1 miss" : `${misses} misses`;
  }

  function renderTypeLive() {
    if (startedAt === null) {
      typeLive.dataset.empty = "";
      typeLive.querySelector("strong").textContent = "--";
      typeStats.textContent = `WPM · 0 of ${countWords(target)} words`;
      return;
    }
    const elapsed = Math.max(now() - startedAt, 1000);
    const wpm = netWpm(prev.length, elapsed, keystrokes, misses);
    const completed = prev.split(" ").length - 1;
    delete typeLive.dataset.empty;
    typeLive.querySelector("strong").textContent = String(Math.round(wpm));
    typeStats.textContent = `WPM · ${completed} of ${countWords(target)} words · ${missLabel()} · ${Math.floor(elapsed / 1000)}s`;
  }

  function resetTyping() {
    clearInterval(typeTimer);
    clearTimeout(countdownTimer);
    countdownTimer = undefined;
    prev = "";
    startedAt = null;
    keystrokes = 0;
    misses = 0;
    typingDone = false;
    typingReady = false;
    typeStart.hidden = false;
    typeStart.disabled = false;
    typeCountdown.hidden = true;
    typeCountdown.textContent = "";
    input.value = "";
    input.disabled = true;
    input.placeholder = typePlaceholder;
    hint.innerHTML = typeHintText;
    renderSentence("");
    renderTypeLive();
  }

  typeStart.addEventListener("click", () => {
    if (typingReady || typingDone || countdownTimer !== undefined) return;
    typeStart.disabled = true;
    typeCountdown.hidden = false;
    const readyAt = now() + 3000;
    function tick() {
      const remaining = Math.ceil((readyAt - now()) / 1000);
      if (remaining > 0) {
        typeCountdown.textContent = `Starting in ${remaining}…`;
        countdownTimer = setTimeout(tick, 1000);
        return;
      }
      countdownTimer = undefined;
      typingReady = true;
      typeStart.hidden = true;
      typeCountdown.textContent = "Go!";
      input.disabled = false;
      input.placeholder = "Type the sentence above.";
      renderSentence(prev);
      input.focus();
    }
    tick();
  });

  function startTyping() {
    if (startedAt !== null) return;
    startedAt = now();
    typeTimer = setInterval(renderTypeLive, 250);
  }

  function finishTyping() {
    const elapsed = now() - startedAt;
    clearInterval(typeTimer);
    const gross = grossWpm(prev.length, elapsed);
    if (prev.length === 0 || !isPlausible(gross, elapsed)) {
      resetTyping();
      hint.textContent = TRY_AGAIN;
      announce(TRY_AGAIN);
      typeStart.focus();
      return;
    }
    const acc = accuracy(keystrokes, misses);
    typed = { wpm: netWpm(prev.length, elapsed, keystrokes, misses), accuracy: acc };
    typingDone = true;
    input.disabled = true;
    typeLive.querySelector("strong").textContent = String(Math.round(typed.wpm));
    typeStats.textContent = `WPM · done · ${Math.round(acc * 100)}% accurate`;
    delete typeLive.dataset.empty;
    announce(`Typing done. ${Math.round(typed.wpm)} words per minute at ${Math.round(acc * 100)} percent accuracy.`);
    afterMeasure();
  }

  input.addEventListener("keydown", (event) => {
    if (!typingReady || typingDone) return;
    if (event.key === "Enter") {
      event.preventDefault();
      if (startedAt !== null) finishTyping();
      return;
    }
    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey) startTyping();
  });
  for (const type of ["paste", "drop", "cut"]) {
    input.addEventListener(type, (event) => event.preventDefault());
  }
  input.addEventListener("input", () => {
    if (!typingReady || typingDone) return;
    const value = input.value.replace(/[\r\n]+/g, "");
    if (value !== input.value) input.value = value;
    if (value.length > 0) startTyping();
    if (value.length > prev.length && value.startsWith(prev)) {
      for (let i = prev.length; i < value.length; i += 1) {
        keystrokes += 1;
        if (value[i] !== target[i]) misses += 1;
      }
    }
    prev = value;
    renderSentence(value);
    renderTypeLive();
    if (value === target) finishTyping();
  });

  /* Speaking */

  function resetSpeaking() {
    clearInterval(speakTimer);
    speakStart = null;
    speakButton.firstChild.textContent = "Start ";
    speakButton.lastElementChild.textContent = "●";
    speakLive.dataset.empty = "";
    speakLive.querySelector("strong").textContent = "--";
    speakStats.textContent = "WPM · not started";
  }

  function renderSpeakLive() {
    const elapsed = now() - speakStart;
    speakLive.querySelector("strong").textContent = (elapsed / 1000).toFixed(1);
    speakStats.textContent = "seconds · timing";
  }

  speakButton.addEventListener("click", () => {
    if (speakStart === null) {
      speakNote.hidden = true;
      speakStart = now();
      speakButton.firstChild.textContent = "Stop ";
      speakButton.lastElementChild.textContent = "■";
      delete speakLive.dataset.empty;
      renderSpeakLive();
      speakTimer = setInterval(renderSpeakLive, 100);
      return;
    }
    const elapsed = now() - speakStart;
    const wpm = speakingWpm(countWords(target), elapsed);
    resetSpeaking();
    if (!isPlausible(wpm, elapsed)) {
      speakNote.textContent = TRY_AGAIN;
      speakNote.hidden = false;
      announce(TRY_AGAIN);
      return;
    }
    spoken = { wpm };
    delete speakLive.dataset.empty;
    speakLive.querySelector("strong").textContent = String(Math.round(wpm));
    speakStats.textContent = "WPM · done";
    announce(`Speaking done. ${Math.round(wpm)} words per minute.`);
    afterMeasure();
  });

  /* Result */

  const pct = (value, scale) => `${Math.min(100, (value / scale) * 100)}%`;

  function afterMeasure() {
    if (typed && spoken) showResult();
    else if (!spoken) go("speak", { focus: true });
    else go("type", { focus: !typed });
  }

  function showResult() {
    const typing = Math.round(typed.wpm);
    const speaking = Math.round(spoken.wpm);
    const ratio = speedup(speaking, typing);
    const saved = Math.round(minutesSaved(speaking, typing));
    const scale = Math.max(190, typing, speaking);

    $("wpm-r-type").textContent = String(typing);
    $("wpm-r-speak").textContent = String(speaking);
    $("wpm-r-type-bar").style.width = pct(typing, scale);
    $("wpm-r-speak-bar").style.width = pct(speaking, scale);
    $("wpm-r-type-avg").style.left = pct(TYPING_WPM, scale);
    $("wpm-r-speak-avg").style.left = pct(SPEAKING_WPM, scale);
    $("wpm-r-type-note").textContent = `Average typist: ${TYPING_WPM}`;
    $("wpm-r-speak-note").textContent = `Average speaker: ${SPEAKING_WPM}`;

    const verdict = $("wpm-verdict");
    const savedLine = $("wpm-saved");
    let summary;
    if (ratio > 1) {
      const mark = document.createElement("mark");
      mark.textContent = `${ratio.toFixed(1)}x`;
      verdict.replaceChildren("You speak ", mark, " faster than you type.");
      summary = `You speak ${ratio.toFixed(1)} times faster than you type.`;
    } else {
      verdict.textContent = "You type as fast as you speak. Nice hands.";
      summary = verdict.textContent;
    }
    if (saved >= 1) {
      savedLine.textContent = `At ${DAILY_WRITING_MINUTES} minutes of writing a day, Mouthtype would save you about ${saved} ${saved === 1 ? "minute" : "minutes"}. Every day.`;
    } else {
      savedLine.textContent = "Mouthtype wouldn't save you much time, but it would rest your hands.";
    }
    go("result", { focus: true });
    announce(`Your result. Typing ${typing} words per minute, speaking ${speaking}. ${summary} ${savedLine.textContent}`);
  }

  for (const button of stepButtons) {
    button.addEventListener("click", () => go(button.dataset.step, { focus: true }));
  }

  /* Easter egg */

  function openPros() {
    const entries = {
      elite: ELITE_TYPIST_WPM,
      average: FOUNDER_AVERAGE_WPM,
      best: FOUNDER_BEST_WPM,
    };
    for (const [key, value] of Object.entries(entries)) {
      pros.querySelector(`[data-pro="${key}"]`).style.width = pct(value, PROS_SCALE_WPM);
      pros.querySelector(`[data-pro-value="${key}"]`).textContent = String(value);
    }
    pros.querySelector("[data-founder-takes]").textContent = String(FOUNDER_TAKES);
    $("wpm-zoom").style.left = pct(FOUNDER_BEST_WPM, PROS_SCALE_WPM);
    const mark = document.createElement("mark");
    mark.textContent = `${speedup(FOUNDER_BEST_WPM, ELITE_TYPIST_WPM).toFixed(1)}x`;
    $("wpm-pros-verdict").replaceChildren("Scott talks ", mark, " faster than an elite typist types.");
    $("wpm-pros-note").textContent = `That's his best single take in Mouthtype, ${FOUNDER_BEST_WPM} WPM. He wasn't typing. Nobody types ${FOUNDER_BEST_WPM}.`;
    main.hidden = true;
    pros.hidden = false;
    const body = pros.querySelector(".wpm-a-result");
    body.tabIndex = -1;
    body.focus();
  }

  function closePros() {
    pros.hidden = true;
    main.hidden = false;
    $("wpm-egg-open").focus();
  }

  $("wpm-egg-open").addEventListener("click", openPros);
  $("wpm-egg-back").addEventListener("click", closePros);
  card.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !pros.hidden) closePros();
  });

  /* Try again */

  $("wpm-again").addEventListener("click", () => {
    typed = null;
    spoken = null;
    resetTyping();
    resetSpeaking();
    speakNote.hidden = true;
    setTarget(pickSentence(target));
    renderTypeLive();
    go("type", { focus: true });
  });

  setTarget(pickSentence(""));
  resetTyping();
  setStep("type");
}
