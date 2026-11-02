import { test, expect } from "@playwright/test";

const paths = ["/", "/download/", "/start/", "/why-mouthtype/", "/compare/", "/compare/apple-dictation/", "/compare/wispr-flow/", "/linux/"];

test("crawl discovery lists canonical indexable pages and docs text", async ({ request }) => {
  const robots = await request.get("/robots.txt");
  expect(robots.status()).toBe(200);
  expect(await robots.text()).toContain("Sitemap: https://mouthtype.app/sitemap.xml");
  const sitemap = await request.get("/sitemap.xml");
  expect(sitemap.status()).toBe(200);
  const xml = await sitemap.text();
  const urls = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1]);
  expect(urls.sort()).toEqual(paths.map((path) => `https://mouthtype.app${path}`).sort());
  for (const url of urls) {
    const page = await request.get(new URL(url).pathname);
    expect(page.status()).toBe(200);
    expect(await page.text()).toContain(`rel="canonical" href="${url}"`);
  }
  const llms = await request.get("/llms.txt");
  expect(llms.status()).toBe(200);
  expect(await llms.text()).toContain("https://docs.mouthtype.app/llms-full.txt");
});

test("security.txt is served as plain text with its canonical URL", async ({ request }) => {
  const response = await request.get("/.well-known/security.txt");
  expect(response.status()).toBe(200);
  expect(response.headers()["content-type"]).toContain("text/plain");
  const body = await response.text();
  expect(body).toContain("Contact: mailto:security@codeswhat.com");
  expect(body).toContain("Canonical: https://mouthtype.app/.well-known/security.txt");
  expect(body).toMatch(/^Expires: \d{4}-\d{2}-\d{2}T[\d:.]+Z$/m);
});
