import { test, expect } from "@playwright/test";
import {
  DAILY_WRITING_MINUTES,
  ELITE_TYPIST_WPM,
  FOUNDER_BEST_WPM,
  SPEAKING_WPM,
  TYPING_WPM,
} from "../src/wpm-constants.js";
import {
  accuracy,
  countWords,
  grossWpm,
  isPlausible,
  minutesSaved,
  netWpm,
  speakingWpm,
  speedup,
} from "../src/wpm-math.js";

const ORANGE = "rgb(239, 139, 67)";

// Math.random() of 0 always picks the first sentence, so runs are repeatable.
async function open(page, { random = 0, clock = true } = {}) {
  await page.addInitScript((value) => {
    Math.random = () => value;
  }, random);
  if (clock) await page.clock.install({ time: 0 });
  await page.goto("/");
  // Paused, so only fastForward moves time and the math is exact.
  if (clock) await page.clock.pauseAt(1000);
  await page.locator("#speed").scrollIntoViewIfNeeded();
  const target = await page.locator("#wpm-sentence").getAttribute("data-target");
  return target;
}

// Types the whole sentence so that it takes `ms` between first key and last.
async function typeIn(page, target, ms, { typo = false } = {}) {
  const box = page.getByLabel("Type the sentence above");
  await box.click();
  await page.keyboard.type(target[0]);
  await page.clock.fastForward(ms);
  if (typo) {
    await page.keyboard.type("##########");
    for (let i = 0; i < 10; i += 1) await page.keyboard.press("Backspace");
  }
  await page.keyboard.type(target.slice(1));
}

async function speakFor(page, ms) {
  await page.getByRole("button", { name: /^Start/ }).click();
  await page.clock.fastForward(ms);
  await page.getByRole("button", { name: /^Stop/ }).click();
}

test.describe("result math", () => {
  test("typing uses characters / 5 / minutes", () => {
    expect(grossWpm(300, 60000)).toBe(60);
    expect(grossWpm(150, 30000)).toBe(60);
    expect(grossWpm(10, 0)).toBe(0);
  });

  test("net WPM is gross scaled by accuracy", () => {
    expect(accuracy(100, 10)).toBeCloseTo(0.9);
    expect(accuracy(0, 0)).toBe(1);
    expect(accuracy(10, 20)).toBe(0);
    expect(netWpm(300, 60000, 100, 10)).toBeCloseTo(54);
  });

  test("speaking is words / minutes", () => {
    expect(speakingWpm(27, 10800)).toBeCloseTo(150);
    expect(countWords("one two  three ")).toBe(3);
    expect(countWords("   ")).toBe(0);
  });

  test("guards reject under 1 second and over 400 WPM", () => {
    expect(isPlausible(150, 999)).toBe(false);
    expect(isPlausible(150, 1000)).toBe(true);
    expect(isPlausible(400, 5000)).toBe(true);
    expect(isPlausible(401, 5000)).toBe(false);
    expect(isPlausible(NaN, 5000)).toBe(false);
  });

  test("speedup and minutes saved", () => {
    expect(speedup(152, 41)).toBeCloseTo(3.707, 2);
    expect(minutesSaved(152, 41)).toBeCloseTo(21.9, 1);
    expect(minutesSaved(150, 40)).toBeCloseTo(22);
    expect(minutesSaved(40, 150)).toBe(0);
    expect(minutesSaved(0, 40)).toBe(0);
    expect(DAILY_WRITING_MINUTES).toBe(30);
  });

  test("the hero uses the same averages", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator(".voice-lane .pace-label")).toContainText(`${SPEAKING_WPM} WPM`);
    await expect(page.locator(".typing-lane .pace-label")).toContainText(`${TYPING_WPM} WPM`);
  });
});

test("the section is linkable at /#speed", async ({ page }) => {
  await page.goto("/#speed");
  await expect(page.locator("#speed")).toBeInViewport();
  await expect(page.getByRole("heading", { name: /Type it\./ })).toBeVisible();
});

test("typing flow with real keystrokes shows live WPM and moves on to speaking", async ({ page }) => {
  const target = await open(page, { clock: false });
  const box = page.getByLabel("Type the sentence above");
  await box.click();
  await page.keyboard.type(target.slice(0, 20), { delay: 50 });
  await expect(page.locator("#wpm-type-live strong")).not.toHaveText("--");
  await expect(page.locator("#wpm-live")).toHaveText("");
  await page.keyboard.type(target.slice(20), { delay: 50 });
  await expect(page.locator("#wpm-speak-panel")).toBeVisible();
  await expect(page.locator("#wpm-live")).toContainText("Typing done");
  await page.getByRole("button", { name: "Type", exact: true }).click();
  const shown = Number(await page.locator("#wpm-type-live strong").textContent());
  // 50 ms per key is about 240 WPM, minus overhead.
  expect(shown).toBeGreaterThan(100);
  expect(shown).toBeLessThan(300);
});

test("typing marks right characters, and the wrong character the user typed in orange", async ({ page }) => {
  const target = await open(page);
  await page.getByLabel("Type the sentence above").click();
  const wrong = target[2] === "x" ? "z" : "x";
  await page.keyboard.type(target.slice(0, 2) + wrong);
  const chars = page.locator("#wpm-sentence i");
  await expect(chars.nth(0)).toHaveAttribute("data-ok", "");
  await expect(chars.nth(1)).toHaveAttribute("data-ok", "");
  const bad = chars.nth(2);
  await expect(bad).toHaveAttribute("data-bad", "");
  await expect(bad).toHaveText(wrong);
  await expect(bad).toHaveCSS("color", ORANGE);
  await expect(chars.nth(3)).toHaveAttribute("data-next", "");
  await page.keyboard.press("Backspace");
  await expect(chars.nth(2)).not.toHaveAttribute("data-bad", "");
  await expect(chars.nth(2)).toHaveText(target[2]);
});

test("typing 60 WPM then speaking 150 WPM gives the exact result card", async ({ page }) => {
  const target = await open(page);
  await typeIn(page, target, target.length * 200); // 60 WPM, no misses
  await expect(page.locator("#wpm-speak-panel")).toBeVisible();
  await expect(page.locator("#wpm-speak-sentence")).toHaveText(target);
  await speakFor(page, countWords(target) * 400); // 150 WPM
  await expect(page.locator("#wpm-result-panel")).toBeVisible();
  await expect(page.locator("#wpm-r-type")).toHaveText("60");
  await expect(page.locator("#wpm-r-speak")).toHaveText("150");
  await expect(page.locator("#wpm-verdict")).toHaveText("You speak 2.5x faster than you type.");
  await expect(page.locator("#wpm-saved")).toContainText("30 minutes of writing a day");
  await expect(page.locator("#wpm-saved")).toContainText("about 18 minutes");
  await expect(page.locator("#wpm-r-type-note")).toHaveText(`Average typist: ${TYPING_WPM}`);
  await expect(page.locator("#wpm-r-speak-note")).toHaveText(`Average speaker: ${SPEAKING_WPM}`);
  await expect(page.getByRole("link", { name: /Download for Mac/ }).first()).toBeVisible();
  await expect(page.locator("#wpm-live")).toContainText("2.5 times faster");
  await expect(page.getByRole("button", { name: "Result", exact: true })).toBeEnabled();
});

test("misses lower net WPM through accuracy", async ({ page }) => {
  const target = await open(page);
  await typeIn(page, target, target.length * 200, { typo: true });
  await speakFor(page, countWords(target) * 400);
  const keystrokes = target.length + 10;
  const expected = Math.round(60 * (1 - 10 / keystrokes));
  await expect(page.locator("#wpm-r-type")).toHaveText(String(expected));
  expect(expected).toBeLessThan(60);
});

test("Enter ends the typing step early", async ({ page }) => {
  const target = await open(page);
  const box = page.getByLabel("Type the sentence above");
  await box.click();
  await page.keyboard.type(target[0]);
  await page.clock.fastForward(2000);
  await page.keyboard.type(target.slice(1, 10));
  await page.keyboard.press("Enter");
  await expect(page.locator("#wpm-speak-panel")).toBeVisible();
  await expect(page.locator("#wpm-live")).toContainText("Typing done");
});

test("typing guard: finishing in under a second says try again", async ({ page }) => {
  const target = await open(page);
  await page.getByLabel("Type the sentence above").click();
  await page.keyboard.type(target);
  await expect(page.locator("#wpm-hint")).toContainText("Try again");
  await expect(page.locator("#wpm-type-panel")).toBeVisible();
  await expect(page.getByLabel("Type the sentence above")).toHaveValue("");
  await expect(page.getByLabel("Type the sentence above")).toBeEnabled();
});

test("speaking guards: under 1 s and over 400 WPM show try again", async ({ page }) => {
  const target = await open(page);
  await page.getByRole("button", { name: "Speak", exact: true }).click();
  await speakFor(page, 500);
  await expect(page.locator("#wpm-speak-note")).toContainText("Try again");
  await expect(page.locator("#wpm-speak-panel")).toBeVisible();
  // 27 words in 1 s is far past 400 WPM.
  await speakFor(page, 1000);
  await expect(page.locator("#wpm-speak-note")).toContainText("Try again");
  await expect(page.getByRole("button", { name: /^Start/ })).toBeVisible();
  // The edge: exactly 400 WPM is fine.
  await speakFor(page, Math.ceil((countWords(target) / 400) * 60000));
  await expect(page.locator("#wpm-speak-note")).toBeHidden();
  await expect(page.locator("#wpm-speak-live strong")).toHaveText("400");
});

test("speaking first then typing still reaches the result", async ({ page }) => {
  const target = await open(page);
  await page.getByRole("button", { name: "Speak", exact: true }).click();
  await speakFor(page, countWords(target) * 400);
  await expect(page.locator("#wpm-type-panel")).toBeVisible();
  await expect(page.getByRole("button", { name: "Result", exact: true })).toBeDisabled();
  await typeIn(page, target, target.length * 200);
  await expect(page.locator("#wpm-result-panel")).toBeVisible();
});

test("Try again resets everything", async ({ page }) => {
  const target = await open(page);
  await typeIn(page, target, target.length * 200);
  await speakFor(page, countWords(target) * 400);
  await page.getByRole("button", { name: "Try again" }).click();
  await expect(page.locator("#wpm-type-panel")).toBeVisible();
  await expect(page.getByLabel("Type the sentence above")).toBeFocused();
  await expect(page.getByLabel("Type the sentence above")).toHaveValue("");
  await expect(page.getByRole("button", { name: "Result", exact: true })).toBeDisabled();
  await expect(page.locator("#wpm-sentence")).not.toHaveAttribute("data-target", target);
});

test("easter egg compares an elite typist with the founder", async ({ page }) => {
  const target = await open(page);
  await typeIn(page, target, target.length * 200);
  await speakFor(page, countWords(target) * 400);
  await page.getByRole("button", { name: /Think you're fast/ }).click();
  const pros = page.locator("#wpm-pros");
  await expect(pros).toBeVisible();
  await expect(page.locator("#wpm-main")).toBeHidden();
  await expect(pros).toContainText("Elite typist");
  await expect(pros).toContainText("Founder, average");
  await expect(pros).toContainText("740 takes in Mouthtype");
  await expect(pros).toContainText("Best take in Mouthtype");
  await expect(pros.locator('[data-pro-value="elite"]')).toHaveText(String(ELITE_TYPIST_WPM));
  await expect(pros.locator('[data-pro-value="average"]')).toHaveText("212");
  await expect(pros.locator('[data-pro-value="best"]')).toHaveText(String(FOUNDER_BEST_WPM));
  await expect(page.locator("#wpm-pros-verdict")).toHaveText(
    "Scott talks 2.8x faster than an elite typist types.",
  );
  await page.keyboard.press("Escape");
  await expect(page.locator("#wpm-result-panel")).toBeVisible();
  await page.getByRole("button", { name: /Think you're fast/ }).click();
  await page.getByRole("button", { name: "Back to my result" }).click();
  await expect(page.locator("#wpm-r-type")).toHaveText("60");
});

test("keyboard operable and results announced only on completion", async ({ page }) => {
  const target = await open(page);
  const live = page.locator("#wpm-live");
  await expect(live).toHaveAttribute("aria-live", "polite");
  await expect(live).toHaveText("");
  await page.getByLabel("Type the sentence above").focus();
  await page.keyboard.type(target[0]);
  await page.clock.fastForward(target.length * 200);
  await page.keyboard.type(target.slice(1, 30));
  await expect(live).toHaveText("");
  await page.keyboard.type(target.slice(30));
  await expect(live).toContainText("Typing done");
  await expect(page.getByRole("button", { name: /^Start/ })).toBeFocused();
  await page.keyboard.press("Enter");
  await page.clock.fastForward(countWords(target) * 400);
  await page.keyboard.press("Space");
  await expect(page.locator("#wpm-result-panel")).toBeVisible();
  await expect(live).toContainText("Your result");
  await expect(page.getByRole("button", { name: "Try again" })).toBeVisible();
});

test("reduced motion disables the caret blink", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page);
  const name = await page
    .locator("#wpm-sentence i[data-next]")
    .evaluate((el) => getComputedStyle(el, "::before").animationName);
  expect(name).toBe("none");
});

test("with motion allowed the caret blinks", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await open(page);
  const name = await page
    .locator("#wpm-sentence i[data-next]")
    .evaluate((el) => getComputedStyle(el, "::before").animationName);
  expect(name).toBe("wpm-blink");
});

test("stores nothing, sends nothing, and respects the CSP", async ({ page }) => {
  const problems = [];
  const external = [];
  page.on("pageerror", (error) => problems.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(message.text());
  });
  page.on("request", (request) => {
    if (!request.url().startsWith("http://127.0.0.1:4177")) external.push(request.url());
    if (request.method() !== "GET") external.push(`${request.method()} ${request.url()}`);
  });
  const target = await open(page);
  await typeIn(page, target, target.length * 200);
  await speakFor(page, countWords(target) * 400);
  await page.getByRole("button", { name: /Think you're fast/ }).click();
  const stored = await page.evaluate(() => ({
    local: localStorage.length,
    session: sessionStorage.length,
    cookie: document.cookie,
  }));
  expect(stored).toEqual({ local: 0, session: 0, cookie: "" });
  expect(external).toEqual([]);
  expect(problems).toEqual([]);
});

test("fits a phone screen", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const target = await open(page);
  await typeIn(page, target, target.length * 200);
  await speakFor(page, countWords(target) * 400);
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - window.innerWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
  await page.getByRole("button", { name: /Think you're fast/ }).click();
  const overflowPros = await page.evaluate(
    () => document.documentElement.scrollWidth - window.innerWidth,
  );
  expect(overflowPros).toBeLessThanOrEqual(0);
});
