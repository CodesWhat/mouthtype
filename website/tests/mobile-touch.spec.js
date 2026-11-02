import { test, expect } from "@playwright/test";

const paths = [
  "/",
  "/download/",
  "/start/",
  "/why-mouthtype/",
  "/linux/",
  "/compare/",
  "/compare/apple-dictation/",
  "/compare/wispr-flow/",
];

const MIN_TAP = 44;
const MIN_TYPE = 10;

test.use({ viewport: { width: 390, height: 844 } });

for (const path of paths) {
  test(`${path} has no horizontal overflow at 390px`, async ({ page }) => {
    await page.goto(path);
    await page.evaluate(() => document.fonts.ready);
    const metrics = await page.evaluate(() => ({
      root: document.documentElement.scrollWidth,
      body: document.body.scrollWidth,
      width: innerWidth,
    }));
    expect(metrics.root).toBeLessThanOrEqual(metrics.width);
    expect(metrics.body).toBeLessThanOrEqual(metrics.width);
  });

  test(`${path} gives every control a 44px hit area at 390px`, async ({
    page,
  }) => {
    await page.goto(path);
    await page.evaluate(() => document.fonts.ready);
    const misses = await page.evaluate((min) => {
      const half = min / 2 - 1.5;
      const selector =
        'a[href], button, input, select, textarea, summary, [role="button"], [tabindex]:not([tabindex="-1"])';
      const misses = [];
      for (const el of document.querySelectorAll(selector)) {
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden") continue;
        if (el.disabled || el.closest(".sr-only, .skip")) continue;
        if (el.classList.contains("skip") || el.classList.contains("sr-only")) continue;
        const target = el.type === "radio" ? el.closest("label") || el : el;
        const rects = target.getClientRects();
        if (!rects.length || !rects[0].width) continue;
        // Links inside running prose are exempt (WCAG 2.5.8 inline exception).
        if (el.tagName === "A") {
          const block = el.closest("p, li, dd, td");
          if (block) {
            const linkText = [...block.querySelectorAll("a")]
              .map((a) => a.textContent.length)
              .reduce((a, b) => a + b, 0);
            if (block.textContent.trim().length - linkText >= 20) continue;
          }
        }
        target.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
        const rect = target.getClientRects()[0];
        const cx = rect.left + rect.width / 2;
        const cy = rect.top + rect.height / 2;
        const probes = [[cx, cy - half], [cx, cy + half]];
        if (rect.width < min) probes.push([cx - half, cy], [cx + half, cy]);
        const failed = probes.filter(([x, y]) => {
          if (x < 0 || x >= innerWidth || y < 0 || y >= innerHeight) return true;
          const hit = document.elementFromPoint(x, y);
          return !hit || !(target.contains(hit) || (hit.closest && hit.closest("label") === target));
        });
        if (failed.length) {
          misses.push(
            `${el.tagName.toLowerCase()}.${el.className} "${(el.textContent || el.name || "").trim().slice(0, 30)}" ${Math.round(rect.width)}x${Math.round(rect.height)}`,
          );
        }
      }
      return misses;
    }, MIN_TAP);
    expect(misses).toEqual([]);
  });

  test(`${path} keeps all visible text at ${MIN_TYPE}px or larger at 390px`, async ({
    page,
  }) => {
    await page.goto(path);
    await page.evaluate(() => document.fonts.ready);
    const small = await page.evaluate((min) => {
      const found = [];
      for (const el of document.querySelectorAll("body *")) {
        if (el.closest(".sr-only")) continue;
        const hasText = [...el.childNodes].some(
          (n) => n.nodeType === 3 && n.textContent.trim(),
        );
        if (!hasText) continue;
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden") continue;
        const rect = el.getBoundingClientRect();
        if (!rect.width || !rect.height) continue;
        const size = parseFloat(style.fontSize);
        if (size < min) {
          found.push(`${el.tagName.toLowerCase()}.${el.className} ${size}px "${el.textContent.trim().slice(0, 30)}"`);
        }
      }
      return found;
    }, MIN_TYPE);
    expect(small).toEqual([]);
  });
}

test("the speed test privacy line is at least 12px at 390px", async ({
  page,
}) => {
  await page.goto("/");
  const size = await page
    .locator(".wpm-a-fine")
    .evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
  expect(size).toBeGreaterThanOrEqual(12);
});

test("the typing box placeholder reads as a clean instruction", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator("#wpm-input")).toHaveAttribute(
    "placeholder",
    "Press “Start typing” to begin.",
  );
});

test("the principles strip pauses on hover and focus", async ({ page }) => {
  await page.goto("/");
  const strip = page.locator(".principles");
  const track = page.locator(".principles-track");
  const state = () =>
    track.evaluate((el) => getComputedStyle(el).animationPlayState);
  expect(await state()).toBe("running");
  await strip.hover();
  expect(await state()).toBe("paused");
  await page.mouse.move(0, 0);
  expect(await state()).toBe("running");
  await strip.focus();
  expect(await state()).toBe("paused");
});

test("the principles strip stops under reduced motion", async ({ browser }) => {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    reducedMotion: "reduce",
  });
  const page = await context.newPage();
  await page.goto("/");
  const name = await page
    .locator(".principles-track")
    .evaluate((el) => getComputedStyle(el).animationName);
  expect(name).toBe("none");
  const hidden = await page
    .locator('.principles-group[aria-hidden="true"]')
    .evaluate((el) => getComputedStyle(el).display);
  expect(hidden).toBe("none");
  await context.close();
});
