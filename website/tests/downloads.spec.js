import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "platform", { value: "MacIntel" });
    Object.defineProperty(navigator, "userAgentData", { value: undefined });
    Object.defineProperty(navigator, "maxTouchPoints", { value: 0 });
  });
});

for (const width of [1440, 320]) {
  test(`the Mac release candidate and matching source can be downloaded at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const download = page.getByRole("link", {
      name: "Download for Mac",
      exact: false,
    });
    await expect(download).toBeVisible();
    await expect(download).toHaveAttribute("href", "/download/");
    await expect(page.locator(".availability")).toContainText("RELEASE CANDIDATE");
    await expect(page.locator(".availability")).toContainText("macOS 26+");
    await expect(page.locator(".availability")).toContainText("APPLE SILICON");
    await expect(page.locator("#alpha")).toContainText("release candidate");
    await expect(page.locator("main")).not.toContainText("private alpha");

    await page.clock.install();
    await download.click();
    await expect(page).toHaveURL(/\/download\/?$/);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("Mouthtype for Mac.");
    await expect(page.locator("main")).toContainText("0.1.0-rc.2");
    await expect(page.getByRole("link", { name: "Source code (GPL-3.0)", exact: false })).toHaveAttribute("href", "/source");
    const starts = [];
    page.on("download", (item) => starts.push(item));
    await page.route("**/download/file", (route) => route.fulfill({
      status: 200,
      headers: { "content-type": "application/zip", "content-disposition": 'attachment; filename="Mouthtype-0.1.0-rc.2-macos-arm64.zip"' },
      body: "Download timing fixture, not a Mouthtype distribution.",
    }));
    await expect(page.getByRole("status")).toContainText("5 seconds");
    await page.clock.runFor(4999);
    expect(starts).toHaveLength(0);
    const result = page.waitForEvent("download");
    await page.clock.runFor(1);
    expect((await result).suggestedFilename()).toBe("Mouthtype-0.1.0-rc.2-macos-arm64.zip");
    await page.clock.runFor(10000);
    expect(starts).toHaveLength(1);
    await expect(page.getByRole("status")).toContainText("requested");
    await expect(page.getByRole("link", { name: "Download now", exact: false })).toBeVisible();
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  });
}

test("installation and update help cover rc.2 and the manual first upgrade", async ({
  page,
}) => {
  await page.goto("/start/");
  await expect(
    page.getByRole("link", { name: "Download for Mac", exact: false }),
  ).toHaveAttribute("href", "/download/");
  await expect(
    page.getByRole("link", { name: "Source code (GPL-3.0)", exact: false }),
  ).toHaveAttribute("href", "/source");
  await expect(page.locator("#install")).not.toContainText(
    "person who invited you",
  );
  await expect(page.locator("#install")).toContainText("0.1.0-rc.2");
  await expect(page.locator("#your-build")).toContainText(
    "General, Writing, Appearance and Diagnostics",
  );
  await page.goto("/docs/#updates");
  await expect(page.locator("#updates")).toContainText("manually");
  await expect(page.locator("#updates")).toContainText("Alpha.1–3");
  await expect(page.locator("#updates")).toContainText("Check for Updates…");
  await expect(page.locator("#updates")).toContainText(
    "Automatically check for updates",
  );
  await expect(page.locator('#updates a[href="/download/"]')).toBeVisible();
  await expect(page.locator('#updates a[href="/source"]')).toBeVisible();
  await expect(page.locator("#local-data")).toContainText(
    "do not upload transcripts or audio",
  );
  await expect(page.locator("#permissions")).toContainText(
    "in-app update installation",
  );
});

test("Download now cancels the countdown and remains available for a retry", async ({ page }) => {
  await page.clock.install();
  await page.route("**/download/file", (route) => route.fulfill({
    status: 200,
    headers: { "content-type": "application/zip", "content-disposition": 'attachment; filename="Mouthtype.zip"' },
    body: "Timing fixture",
  }));
  const starts = [];
  page.on("download", (item) => starts.push(item));
  await page.goto("/download/");
  const link = page.getByRole("link", { name: "Download now", exact: false });
  const result = page.waitForEvent("download");
  await link.click();
  await result;
  await page.clock.runFor(10000);
  expect(starts).toHaveLength(1);
  const retry = page.waitForEvent("download");
  await link.click();
  await retry;
  expect(starts).toHaveLength(2);
});

test("the landing page and direct download work without JavaScript", async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  try {
    const page = await context.newPage();
    await page.route("**/download/file", (route) => route.fulfill({
      status: 200,
      headers: { "content-type": "application/zip", "content-disposition": 'attachment; filename="Mouthtype.zip"' },
      body: "No-JavaScript fixture",
    }));
    await page.goto("/download/");
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("Mouthtype for Mac.");
    const result = page.waitForEvent("download");
    await page.getByRole("link", { name: "Download now", exact: false }).click();
    await result;
  } finally { await context.close(); }
});
