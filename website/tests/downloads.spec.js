import { test, expect } from "@playwright/test";

for (const width of [1440, 320]) {
  test(`the Mac alpha and matching source can be downloaded at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const download = page.getByRole("link", {
      name: "Download for Mac",
      exact: false,
    });
    await expect(download).toBeVisible();
    await expect(download).toHaveAttribute("href", "/download");
    await expect(page.locator(".availability")).toContainText("ALPHA");
    await expect(page.locator(".availability")).toContainText("macOS 26+");
    await expect(page.locator(".availability")).toContainText("APPLE SILICON");
    await expect(page.locator("#alpha")).toContainText("alpha");
    await expect(page.locator("main")).not.toContainText("private alpha");

    for (const [path, filename, link] of [
      ["/download", "Mouthtype-0.1.0-alpha.4-macos-arm64.zip", download],
      [
        "/source",
        "Mouthtype-0.1.0-alpha.4-source.tar.gz",
        page.getByRole("link", { name: "Source code (GPL-3.0)", exact: false }),
      ],
    ]) {
      await expect(link).toHaveAttribute("href", path);
      await page.route(`**${path}`, (route) =>
        route.fulfill({
          status: 200,
          headers: {
            "content-type": "application/octet-stream",
            "content-disposition": `attachment; filename="${filename}"`,
          },
          body: "Endpoint contract fixture, not a Mouthtype distribution.",
        }),
      );
      const result = page.waitForEvent("download");
      await link.click();
      expect((await result).suggestedFilename()).toBe(filename);
      await expect(page.locator("#hero-title")).toBeVisible();
    }
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  });
}

test("installation and update help cover alpha.4 and the manual first upgrade", async ({
  page,
}) => {
  await page.goto("/start/");
  await expect(
    page.getByRole("link", { name: "Download for Mac", exact: false }),
  ).toHaveAttribute("href", "/download");
  await expect(
    page.getByRole("link", { name: "Source code (GPL-3.0)", exact: false }),
  ).toHaveAttribute("href", "/source");
  await expect(page.locator("#install")).not.toContainText(
    "person who invited you",
  );
  await expect(page.locator("#install")).toContainText("0.1.0-alpha.4");
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
  await expect(page.locator('#updates a[href="/download"]')).toBeVisible();
  await expect(page.locator('#updates a[href="/source"]')).toBeVisible();
  await expect(page.locator("#local-data")).toContainText(
    "do not upload transcripts or audio",
  );
  await expect(page.locator("#permissions")).toContainText(
    "in-app update installation",
  );
});
