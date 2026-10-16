import { test, expect } from "@playwright/test";

for (const [choice, title, tagline] of [
  [0, "Words, straight", "SOFTWARE FOR SAYING THINGS"],
  [0.99, "Say it.", "FROM YOUR HEAD. THROUGH YOUR MOUTH."],
]) {
  test(`headline stays fixed after loading ${title}`, async ({ page }) => {
    await page.addInitScript((value) => {
      Math.random = () => value;
    }, choice);
    await page.clock.install();
    await page.goto("/");
    await expect(page.locator("h1")).toContainText(title);
    await expect(page.locator("#hero-tagline")).toHaveText(tagline);
    await expect(page.locator("#headline-control, .orbit")).toHaveCount(0);
    await page.clock.fastForward(60000);
    await expect(page.locator("h1")).toContainText(title);
    await page.reload();
    await expect(page.locator("h1")).toContainText(title);
  });
}

test("real pill assets and prepared cleanup example work", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await expect(page.locator("#pill-preview")).toHaveAttribute(
    "src",
    /classic-recording/,
  );
  await page.getByLabel("Hi-Fi", { exact: true }).check();
  await expect(page.locator("#pill-preview")).toHaveAttribute(
    "src",
    /hifi-recording/,
  );
  await expect(page.locator("#pill-preview")).toHaveJSProperty(
    "naturalWidth",
    584,
  );
  await page.getByRole("button", { name: "As spoken", exact: true }).click();
  await expect(page.locator("#example-text")).toContainText("um send");
  await page.getByRole("button", { name: "Cleaned up", exact: true }).click();
  await expect(page.locator("#example-text")).toHaveText(
    "Send the mockups to Sean before Friday.",
  );
  await expect(page.locator("#example-note")).toContainText(
    "Saved spelling applied.",
  );
  expect(errors).toEqual([]);
});

for (const width of [1440, 768, 390, 320]) {
  test(`layout and local links fit at ${width}px`, async ({
    page,
  }, testInfo) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    await page.evaluate(() => document.fonts.ready);
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
    const hero = await page.locator(".hero").boundingBox();
    const status = await page.locator(".platform-status").boundingBox();
    expect(
      Math.abs(status.x + status.width - hero.x - hero.width),
    ).toBeLessThan(2);
    expect(status.y - hero.y).toBeLessThan(25);
    expect(
      await page.locator(".edition, .feature-steps, #preview-note").count(),
    ).toBe(0);
    const brokenLinks = await page
      .locator('a[href^="#"]')
      .evaluateAll((links) =>
        links
          .map((link) => link.getAttribute("href"))
          .filter(
            (href) =>
              href.length > 1 && !document.getElementById(href.slice(1)),
          ),
      );
    expect(brokenLinks).toEqual([]);
    expect(
      await page
        .locator("img")
        .evaluateAll((images) =>
          images.every((image) => image.complete && image.naturalWidth > 0),
        ),
    ).toBe(true);
    await page.screenshot({
      path: testInfo.outputPath("page.png"),
      fullPage: true,
    });
  });
}

test("production response applies the deployment policy", async ({
  request,
}) => {
  const response = await request.get("/");
  expect(response.status()).toBe(200);
  expect(response.headers()["content-security-policy"]).toContain(
    "script-src 'self'",
  );
  expect(response.headers()["permissions-policy"]).toContain("microphone=()");
  expect(response.headers()["x-content-type-options"]).toBe("nosniff");
});

test("hero cycles examples at labelled paces without moving its layout", async ({
  page,
}, testInfo) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.clock.install();
  await page.goto("/");
  await page.locator(".product-preview").scrollIntoViewIfNeeded();
  await expect(page.locator("#voice-copy")).toBeVisible();
  await expect(page.locator(".voice-lane .pace-label")).toContainText("180 WPM");
  await expect(page.locator(".typing-lane .pace-label")).toContainText("45 WPM");
  const regions = [".preview-paper", ".voice-lane", ".typing-lane", ".pill-slot", ".shortcut-hint", ".skin-controls"];
  const bounds = await Promise.all(regions.map((selector) => page.locator(selector).boundingBox()));
  await page.clock.runFor(3000);
  await expect(page.locator("#voice-copy")).toHaveText(
    "I'll send the first draft before lunch.",
  );
  expect((await page.locator("#typing-copy").innerText()).length).toBeLessThan(
    38,
  );
  await page.screenshot({
    path: testInfo.outputPath("pace-comparison.png"),
    fullPage: false,
  });
  await page.clock.runFor(8000);
  await expect(page.locator("#typing-copy")).toHaveText(
    "I'll send the first draft before lunch.",
  );
  await page.clock.runFor(5000);
  await expect(page.locator("#voice-copy")).not.toHaveText("I'll send the first draft before lunch.");
  await page.clock.runFor(20000);
  await expect(page.locator(".product-preview")).toHaveAttribute(
    "data-demo",
    "running",
  );
  expect(await Promise.all(regions.map((selector) => page.locator(selector).boundingBox()))).toEqual(bounds);
  await page.getByLabel("Hi-Fi", { exact: true }).check();
  expect(await Promise.all(regions.map((selector) => page.locator(selector).boundingBox()))).toEqual(bounds);
  const legend = await page.locator(".skin-controls legend").boundingBox();
  const controls = await page.locator(".skin-controls").boundingBox();
  expect(Math.abs(legend.x + legend.width / 2 - controls.x - controls.width / 2)).toBeLessThan(1);
  await expect(page.locator(".asset-caption")).toHaveCount(0);
});

test("principles move right continuously and stop for reduced motion", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/");
  const track = page.locator(".principles-track");
  await expect(track).toHaveCount(1);
  const positions = await track.evaluate(async (element) => {
    const animation = element.getAnimations()[0];
    animation.pause();
    animation.currentTime = 0;
    await new Promise(requestAnimationFrame);
    const before = element.getBoundingClientRect().x;
    animation.currentTime = 2000;
    await new Promise(requestAnimationFrame);
    return [before, element.getBoundingClientRect().x];
  });
  expect(positions[1]).toBeGreaterThan(positions[0] + 10);
  await expect(page.locator('.principles-group[aria-hidden="true"]')).toHaveCount(1);
  const groups = await page.locator(".principles-group").evaluateAll((elements) => elements.map((element) => element.getBoundingClientRect().width));
  expect(groups[0]).toBeCloseTo(groups[1], 3);
  expect((await track.boundingBox()).width).toBeCloseTo(groups[0] * 2, 2);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(track).toHaveCSS("animation-name", "none");
  await page.locator(".principles").scrollIntoViewIfNeeded();
  for (const title of ["On your machine.", "In your own words.", "Out of your way."]) {
    await expect(page.getByText(title, { exact: true }).first()).toBeInViewport();
  }
});

test("mobile example cycles and both skins keep their reserved space", async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 950 });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.clock.install();
  await page.goto("/");
  await page.evaluate(() => document.fonts.ready);
  await page.locator(".product-preview").scrollIntoViewIfNeeded();
  const paper = await page.locator(".preview-paper").boundingBox();
  const controls = await page.locator(".skin-controls").boundingBox();
  const initialScroll = await page.evaluate(() => scrollY);
  for (const step of [3000, 12500, 12500]) {
    await page.clock.runFor(step);
    const fits = await page.locator(".pace-lane p").evaluateAll((elements) =>
      elements.every((element) => element.scrollHeight <= element.clientHeight && element.scrollWidth <= element.clientWidth));
    expect(fits).toBe(true);
    expect(await page.locator(".preview-paper").boundingBox()).toEqual(paper);
  }
  await page.getByLabel("Hi-Fi", { exact: true }).check();
  const after = await page.locator(".skin-controls").boundingBox();
  expect(after.y + await page.evaluate(() => scrollY)).toEqual(controls.y + initialScroll);
  expect({ ...after, y: controls.y }).toEqual(controls);
});

test("reduced motion shows the finished comparison without animation", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  await expect(page.locator(".product-preview")).toHaveAttribute(
    "data-demo",
    "complete",
  );
  await expect(page.locator("#voice-copy")).toHaveText(
    "I'll send the first draft before lunch.",
  );
  await expect(page.locator("#typing-copy")).toHaveText(
    "I'll send the first draft before lunch.",
  );
  const pill = await page.locator("#pill-preview").boundingBox();
  const typed = await page.locator("#typing-copy").boundingBox();
  expect(pill.y - typed.y - typed.height).toBeGreaterThanOrEqual(0);
  const hint = await page.locator(".shortcut-hint").boundingBox();
  expect(hint.y - pill.y - pill.height).toBeGreaterThanOrEqual(18);
  const key = await page.locator(".shortcut-hint kbd").boundingBox();
  const label = await page.locator(".shortcut-hint span").boundingBox();
  expect(key.x + key.width).toBeLessThan(label.x);
});

test("a pending hero still starts after returning from page cache", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 200 });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/");
  await expect(page.locator("#voice-copy")).toHaveText("");
  await page.evaluate(() => {
    dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true }));
  });
  await expect(page.locator("#voice-copy")).toHaveText("");
  await page.evaluate(() => {
    dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));
  });
  await page.locator(".product-preview").scrollIntoViewIfNeeded();
  await expect(page.locator(".product-preview")).toHaveAttribute("data-demo", "running");
  await expect(page.locator("#voice-copy")).not.toHaveText("");
});
