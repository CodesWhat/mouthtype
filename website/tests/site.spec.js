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
