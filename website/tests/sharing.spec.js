import { test, expect } from "@playwright/test";

test.use({ javaScriptEnabled: false });

for (const route of [
  "/",
  "/start/",
  "/download/",
  "/linux/",
  "/why-mouthtype/",
  "/compare/",
  "/compare/apple-dictation/",
  "/compare/wispr-flow/",
]) {
  test(`sharing metadata and image work without JavaScript at ${route}`, async ({
    page,
    request,
  }) => {
    await page.goto(route);
    const meta = (name) => page.locator(`meta[property="${name}"]`);
    const canonical = `https://mouthtype.app${route}`;
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", canonical);
    await expect(meta("og:url")).toHaveAttribute("content", canonical);
    await expect(meta("og:title")).toHaveAttribute("content", await page.title());
    await expect(meta("og:description")).toHaveAttribute(
      "content",
      await page.locator('meta[name="description"]').getAttribute("content"),
    );
    await expect(meta("og:site_name")).toHaveAttribute("content", "Mouthtype");
    await expect(meta("og:type")).toHaveAttribute("content", "website");
    await expect(page.locator('meta[name="twitter:card"]')).toHaveAttribute("content", "summary_large_image");
    const image = new URL(await meta("og:image").getAttribute("content"));
    expect(image.origin).toBe("https://mouthtype.app");
    await expect(page.locator('meta[name="twitter:image"]')).toHaveAttribute("content", image.href);
    await expect(meta("og:image:alt")).toHaveAttribute("content", /Mouthtype/);
    const response = await request.get(image.pathname);
    expect(response.status()).toBe(200);
    expect(response.headers()["content-type"]).toContain("image/png");
    const bytes = await response.body();
    expect(bytes.subarray(0, 8).toString("hex")).toBe("89504e470d0a1a0a");
    expect(bytes.length).toBeLessThan(1_000_000);
    expect(bytes.readUInt32BE(16)).toBe(1200);
    expect(bytes.readUInt32BE(20)).toBe(630);
    await expect(meta("og:image:width")).toHaveAttribute("content", "1200");
    await expect(meta("og:image:height")).toHaveAttribute("content", "630");
  });
}
