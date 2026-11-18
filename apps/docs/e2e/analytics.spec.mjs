import { gunzipSync } from "node:zlib";
import { expect, test } from "@playwright/test";

const INGESTION = "https://e.codeswhat.com";
const SELF = "http://127.0.0.1:4178";
const GUIDE = "/dictating/";

// posthog-js drops events from automated browsers (headless user agent, navigator.webdriver), so
// present an ordinary desktop Chrome. Ingestion is answered locally; nothing reaches the network.
test.use({
  userAgent:
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
});

test.beforeEach(async ({ page, context }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
    Object.defineProperty(navigator, "userAgentData", {
      get: () => ({ brands: [{ brand: "Chromium", version: "130" }], mobile: false }),
    });
  });
  const sent = [];
  await context.route(`${INGESTION}/**`, (route) => {
    sent.push(route.request());
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: '{"status":1}',
    });
  });
  await context.route("https://mouthtype.app/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/html", body: "site" }),
  );
  page.sent = sent;
});

function events(page) {
  return page.sent.flatMap((request) => {
    const raw = request.postDataBuffer();
    if (!raw) return [];
    let text;
    try {
      text = gunzipSync(raw).toString("utf8");
    } catch {
      text = raw.toString("utf8");
    }
    const body = JSON.parse(text);
    return Array.isArray(body) ? body : (body.batch ?? [body]);
  });
}

async function waitFor(page, name) {
  await expect.poll(() => events(page).some((event) => event.event === name)).toBe(true);
  return events(page).filter((event) => event.event === name);
}

test("a guide load sends a sanitized pageview and stays within self and the ingestion host", async ({
  page,
}) => {
  const problems = [];
  page.on("pageerror", (error) => problems.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(message.text());
  });
  page.on("request", (request) => {
    const url = request.url();
    const origin = url.startsWith("data:") ? "data:" : new URL(url).origin;
    if (
      origin !== new URL(SELF).origin &&
      origin !== new URL(INGESTION).origin &&
      origin !== "data:"
    ) {
      problems.push(`outside request: ${url}`);
    }
  });
  await page.goto(`${GUIDE}?q=secret&email=a%40b.example#frag`, {
    referer: "https://news.ycombinator.com/item?id=123456",
  });
  const [pageview] = await waitFor(page, "$pageview");
  expect(pageview.properties).toMatchObject({
    schema_version: 1,
    site: "mouthtype",
    surface: "docs",
    path: "/dictating",
    $pathname: "/dictating",
    $referring_domain: "news.ycombinator.com",
  });
  const wire = JSON.stringify(events(page));
  for (const leaked of ["a@b.example", "secret", "123456", "$referrer", "$current_url"]) {
    expect(wire).not.toContain(leaked);
  }
  expect(problems).toEqual([]);
});

test("the Download link reports the download CTA", async ({ page }) => {
  await page.goto("/");
  await waitFor(page, "$pageview");
  await page.evaluate(() => {
    document.addEventListener("click", (event) => event.preventDefault());
  });
  await page
    .locator('a[href="https://mouthtype.app/download"]')
    .locator("visible=true")
    .first()
    .click();
  const ctas = await waitFor(page, "cta activated");
  expect(ctas.map((event) => event.properties.cta_id)).toEqual(["download"]);
  expect(ctas[0].properties).toMatchObject({ site: "mouthtype", surface: "docs", path: "/" });
});

test("a Global Privacy Control signal turns analytics off", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "globalPrivacyControl", { value: true });
  });
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(500);
  expect(page.sent).toEqual([]);
});

test("web vitals go out once, by beacon, when the page is hidden", async ({
  page,
  browserName,
}) => {
  test.skip(browserName !== "chromium", "beacon interception is asserted on Chromium");
  await page.goto("/");
  await waitFor(page, "$pageview");
  await page.waitForFunction(
    () => performance.getEntriesByName("first-contentful-paint").length > 0,
  );
  await page.waitForTimeout(500);
  expect(events(page).filter((event) => event.event === "$web_vitals")).toEqual([]);

  // A real navigation cancels the beacon before Playwright can route it, so fire the lifecycle
  // events the browser would: hidden first, then pagehide. Our listeners run ahead of PostHog's.
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { get: () => "hidden" });
    document.dispatchEvent(new Event("visibilitychange"));
    window.dispatchEvent(new Event("pagehide"));
  });
  const [vitals] = await waitFor(page, "$web_vitals");
  expect(vitals.properties.$web_vitals_FCP_value).toBeGreaterThan(0);
  await page.waitForTimeout(500);
  expect(events(page).filter((event) => event.event === "$web_vitals")).toHaveLength(1);
});
