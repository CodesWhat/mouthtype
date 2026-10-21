import { test, expect } from "@playwright/test";

const pages = [
  ["/start/", "Your first words."],
  ["/linux/", "Mouthtype for Linux."],
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
      ["Docs", "https://docs.mouthtype.app/"],
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
  await expect(page.locator("main")).toContainText("0.4.0");
  await expect(page.locator("#install")).toContainText("Download");
  await expect(page.locator("#permissions")).toContainText("Microphone");
  await expect(page.locator("#permissions")).toContainText("Accessibility");
  await expect(page.locator("#first-take")).toContainText("release");
  await expect(page.locator("#your-build")).toContainText("Settings");
  await expect(page.locator("#your-build")).toContainText("Transcribe Audio File…");
  await expect(page.locator("#your-build")).toContainText("Live words");
  await expect(page.locator('#your-build a[href="https://docs.mouthtype.app/transcribe-audio-files/"]')).toBeVisible();
  await page.getByRole("link", { name: "If something gets stuck" }).click();
  await expect(page.locator("#help")).toBeInViewport();
  await expect(page.locator("#help")).toContainText("already appeared");
  await expect(page.locator('input, form, [href$=".zip"]')).toHaveCount(0);
});

test("start links into the docs site and the old /docs/ page redirects there", async ({
  page,
}) => {
  await page.goto("/start/");
  const docs = "https://docs.mouthtype.app";
  await expect(page.getByRole("link", { name: "Read the documentation" })).toHaveAttribute(
    "href",
    `${docs}/`,
  );
  for (const [name, href] of [
    ["app and website tone rules", `${docs}/cleanup-and-style/`],
    ["microphone priorities", `${docs}/dictating/#choose-a-microphone`],
    ["file transcription guide", `${docs}/transcribe-audio-files/`],
    ["saved audio", `${docs}/privacy-and-data/`],
    ["Check for Updates…", `${docs}/getting-started/install-notes/#updates`],
    ["Linux source testing", `${docs}/linux/`],
  ]) {
    await expect(page.getByRole("link", { name: new RegExp(name) })).toHaveAttribute(
      "href",
      href,
    );
  }
});

for (const [anchor, target] of [
  ["", "/"],
  ["#builds", "/getting-started/"],
  ["#shortcuts", "/dictating/#change-the-shortcut"],
  ["#fn-key", "/troubleshooting/#fn-doesnt-start-dictation-or-the-emoji-picker-opens"],
  ["#recording-options", "/dictating/#choose-a-microphone"],
  ["#file-transcription", "/transcribe-audio-files/"],
  ["#cleanup", "/cleanup-and-style/"],
  ["#spellings-phrases", "/dictionary/"],
  ["#recent-stats", "/reference/settings/"],
  ["#learned-corrections", "/dictionary/#suggestions"],
  ["#advanced-writing", "/reference/settings/"],
  ["#recovery", "/dictating/#when-a-paste-doesnt-land"],
  ["#updates", "/getting-started/install-notes/#updates"],
  ["#local-data", "/privacy-and-data/"],
  ["#permissions", "/getting-started/#allow-microphone-and-accessibility"],
  ["#troubleshooting", "/troubleshooting/"],
  ["#known-limits", "/reference/known-limits/"],
  ["#linux", "/linux/"],
  ["#not-an-old-anchor", "/"],
]) {
  test(`/docs/${anchor} redirects to docs.mouthtype.app${target}`, async ({ page }) => {
    await page.route("https://docs.mouthtype.app/**", (route) =>
      route.fulfill({ status: 200, contentType: "text/html", body: "<h1>docs</h1>" }),
    );
    await page.goto(`/docs/${anchor}`);
    await page.waitForURL(`https://docs.mouthtype.app${target}`);
  });
}

test.describe("without JavaScript", () => {
  test.use({ javaScriptEnabled: false });

  test("/docs/ keeps a meta refresh and a plain link to the docs site", async ({ page }) => {
    await page.goto("/docs/");
    await expect(page.locator('meta[http-equiv="refresh"]')).toHaveAttribute(
      "content",
      /url=https:\/\/docs\.mouthtype\.app\//,
    );
    await expect(page.getByRole("link", { name: /Open the documentation/ })).toHaveAttribute(
      "href",
      "https://docs.mouthtype.app/",
    );
  });
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
