import { test, expect } from "@playwright/test";

const pages = [
  ["/start/", "Your first words."],
  ["/linux/", "Mouthtype for Linux."],
  ["/docs/", "The useful details."],
  ["/why-mouthtype/", "A little less between you and your words."],
  ["/compare/", "Find your fit."],
  ["/compare/apple-dictation/", "Mouthtype and Apple Dictation."],
  ["/compare/wispr-flow/", "Mouthtype and Wispr Flow."],
];

for (const width of [1440, 320]) {
  test(`homepage navigation reaches the real pages at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const nav = page.getByRole("navigation", { name: "Main" });
    for (const [name, path] of [
      ["Why Mouthtype", "/why-mouthtype/"],
      ["Compare", "/compare/"],
      ["Docs", "/docs/"],
      ["Get started", "/start/"],
    ]) {
      const link = nav.getByRole("link", { name });
      await expect(link).toBeVisible();
      await expect(link).toHaveAttribute("href", path);
      if (width === 320) {
        const bounds = await link.boundingBox();
        expect(bounds.height).toBeLessThan(name === "Get started" ? 36 : 24);
      }
    }
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
    await nav.getByRole("link", { name: "Docs" }).click();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      "The useful details.",
    );
    await page.getByRole("link", { name: "Mouthtype home" }).click();
    await expect(page.locator("#hero-title")).toBeVisible();
  });
}

for (const [path, heading] of pages) {
  test(`${path} is a real, directly loadable page`, async ({ page }) => {
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const response = await page.goto(path);
    expect(response.status()).toBe(200);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(heading);
    await page.reload();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(heading);
    await expect(page.getByRole("navigation", { name: "Main" })).toBeVisible();
    await expect(
      page
        .getByRole("navigation", { name: "Main" })
        .getByRole("link", { name: "Docs" }),
    ).toBeVisible();
    expect(errors).toEqual([]);
  });
}

test("start describes the current release features", async ({ page }) => {
  await page.goto("/start/");
  await expect(page.locator("main")).toContainText("0.3.0");
  await expect(page.locator("#install")).toContainText("Download");
  await expect(page.locator("#permissions")).toContainText("Microphone");
  await expect(page.locator("#permissions")).toContainText("Accessibility");
  await expect(page.locator("#first-take")).toContainText("release");
  await expect(page.locator("#your-build")).toContainText("Settings");
  await expect(page.locator("#your-build")).toContainText("Transcribe Audio File…");
  await expect(page.locator("#your-build")).toContainText("Live words");
  await expect(page.locator('#your-build a[href="/docs/#file-transcription"]')).toBeVisible();
  await page.getByRole("link", { name: "If something gets stuck" }).click();
  await expect(page.locator("#help")).toBeInViewport();
  await expect(page.locator("#help")).toContainText("already appeared");
  await expect(page.locator('input, form, [href$=".zip"]')).toHaveCount(0);
});

test("reference help covers everyday tasks with explicit build labels", async ({
  page,
}) => {
  await page.goto("/start/");
  await page.getByRole("link", { name: "Read the documentation" }).click();
  await expect(page).toHaveURL(/\/docs\/$/);
  for (const id of [
    "shortcuts",
    "cleanup",
    "recording-options",
    "file-transcription",
    "linux",
    "spellings-phrases",
    "recovery",
    "local-data",
    "permissions",
  ]) {
    await expect(page.locator(`#${id}`)).toBeVisible();
  }
  await expect(page.locator("#builds")).toContainText("0.3.0");
  await expect(page.locator("#builds")).toContainText("Settings");
  await expect(page.locator("#builds")).not.toContainText("reference describes alpha.5");
  await expect(page.locator("#recording-options")).toContainText("Live words");
  await expect(page.locator("#recording-options")).toContainText("off by default");
  await expect(page.locator("#file-transcription")).toContainText("Transcribe Audio File…");
  await expect(page.locator("#file-transcription")).toContainText("10 minutes");
  await expect(page.locator("#file-transcription")).toContainText("512 MB");
  await expect(page.locator("#file-transcription")).toContainText("Copy");
  await expect(page.locator("#file-transcription")).toContainText("Save Text…");
  await expect(page.locator("#linux")).toContainText("experimental");
  await expect(page.locator("#linux")).toContainText("source-only");
  await expect(page.locator("#linux")).toContainText("Arch/Omarchy");
  await expect(page.locator("#cleanup")).toContainText("per-app");
  await expect(page.locator("#local-data")).toContainText("90 days");
  await expect(page.locator("#local-data")).toContainText("Saved audio");
  await expect(page.locator("#local-data")).toContainText("14, 30 or 90 days");
  await expect(page.locator("#local-data")).toContainText("10 GB");
  await expect(page.locator("#local-data")).toContainText("Unfinished recordings");
  await expect(page.locator("#linux")).toContainText("saved spellings and phrase replacements");
  await expect(page.locator("#linux")).toContainText("multiline");
  await page.getByRole("link", { name: "Start with your first take" }).click();
  await expect(page).toHaveURL(/\/start\/$/);
});

test("comparison pages cite official sources and keep the tradeoffs visible", async ({
  page,
}) => {
  await page.goto("/compare/apple-dictation/");
  await expect(page.locator("main")).toContainText("on-device");
  await expect(page.locator("main")).toContainText("automatic punctuation");
  await expect(
    page.locator('main a[href^="https://support.apple.com/"]'),
  ).not.toHaveCount(0);
  await page.goto("/compare/wispr-flow/");
  await expect(page.locator("main")).toContainText("cloud");
  await expect(page.locator("main")).toContainText("Windows");
  await expect(page.locator("main")).toContainText("stable release");
  await expect(
    page.locator('main a[href^="https://docs.wisprflow.ai/"]'),
  ).not.toHaveCount(0);
});

test("mobile comparisons keep both products readable without sideways scrolling", async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 900 });
  await page.goto("/compare/wispr-flow/");
  const cells = await page.locator("tbody td").evaluateAll((items) =>
    items.map((item) => {
      const bounds = item.getBoundingClientRect();
      return { left: bounds.left, right: bounds.right };
    }),
  );
  for (const cell of cells) {
    expect(cell.left).toBeGreaterThanOrEqual(0);
    expect(cell.right).toBeLessThanOrEqual(320);
  }
  await expect(page.locator(".page-lede")).toHaveText(
    "A similar idea. Different places for the work to happen.",
  );
});

for (const width of [1440, 320]) {
  test(`pages fit and internal links resolve at ${width}px`, async ({
    page,
    request,
  }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    const internal = new Set();
    for (const [path, heading] of pages) {
      await page.goto(path);
      await page.evaluate(() => document.fonts.ready);
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      ).toBe(true);
      await expect(page.getByRole("heading", { level: 1 })).toHaveText(heading);
      const links = await page
        .locator('a[href^="/"]')
        .evaluateAll((items) => items.map((item) => item.getAttribute("href")));
      links
        .filter((href) => !["/download", "/source"].includes(href))
        .forEach((href) => internal.add(href));
      const broken = await page
        .locator('a[href^="#"]')
        .evaluateAll((items) =>
          items
            .map((item) => item.hash.slice(1))
            .filter((id) => id && !document.getElementById(id)),
        );
      expect(broken).toEqual([]);
      expect(
        await page
          .locator("img")
          .evaluateAll((items) =>
            items.every((item) => item.complete && item.naturalWidth > 0),
          ),
      ).toBe(true);
      await page.screenshot({
        path: testInfo.outputPath(`${path.replaceAll("/", "-")}.png`),
        fullPage: true,
      });
    }
    for (const href of internal) {
      const response = await request.get(href);
      expect(response.status(), href).toBe(200);
    }
  });
}
