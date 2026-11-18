import { gunzipSync } from "node:zlib";
import { expect, INGESTION_ORIGIN, test } from "./fixtures.js";

// posthog-js drops events from automated browsers (headless user agent, navigator.webdriver), so
// present an ordinary desktop Chrome.
test.use({
  userAgent:
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
});

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
    Object.defineProperty(navigator, "userAgentData", {
      get: () => ({ brands: [{ brand: "Chromium", version: "130" }], mobile: false, platform: "macOS" }),
    });
  });
});

const SELF = "http://127.0.0.1:4177";
const PAGES = [
  ["/", "/"],
  ["/start/", "/start"],
  ["/download/", "/download"],
  ["/linux/", "/linux"],
  ["/why-mouthtype/", "/why-mouthtype"],
  ["/compare/", "/compare"],
  ["/compare/apple-dictation/", "/compare/apple-dictation"],
  ["/compare/wispr-flow/", "/compare/wispr-flow"],
];

// On a Mac the download page starts the file by itself after a countdown. Report a touch device
// so the page stays put while the test clicks.
async function stayOnDownloadPage(page) {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "maxTouchPoints", { get: () => 5 });
  });
}

function decode(request) {
  const raw = request.postDataBuffer();
  if (!raw) return [];
  let text;
  try {
    text = gunzipSync(raw).toString("utf8");
  } catch {
    text = raw.toString("utf8");
  }
  if (text.startsWith("data=")) {
    text = Buffer.from(decodeURIComponent(text.slice(5)), "base64").toString("utf8");
  }
  const body = JSON.parse(text);
  return Array.isArray(body) ? body : (body.batch ?? [body]);
}

function sentEvents(analytics) {
  return analytics.flatMap(decode);
}

async function waitForEvent(analytics, name) {
  await expect
    .poll(() => sentEvents(analytics).some((event) => event.event === name), { timeout: 10000 })
    .toBe(true);
  return sentEvents(analytics).filter((event) => event.event === name);
}

function watchProblems(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(message.text());
  });
  page.on("request", (request) => {
    const url = request.url();
    const origin = url.startsWith("data:") ? "data:" : new URL(url).origin;
    if (origin !== new URL(SELF).origin && origin !== new URL(INGESTION_ORIGIN).origin && origin !== "data:") {
      problems.push(`outside request: ${url}`);
    }
  });
  return problems;
}

for (const [url, path] of PAGES) {
  test(`${url} sends a sanitized pageview and nothing outside self and the ingestion host`, async ({
    page,
    analytics,
  }) => {
    const problems = watchProblems(page);
    await page.goto(`${url}?utm_source=mail&email=a%40b.example#section`);
    const [pageview] = await waitForEvent(analytics, "$pageview");
    expect(pageview.properties).toMatchObject({
      schema_version: 1,
      site: "mouthtype",
      surface: "marketing",
      path,
      $pathname: path,
      $process_person_profile: false,
      $cookieless_mode: true,
    });
    const wire = JSON.stringify(sentEvents(analytics));
    expect(wire).not.toContain("a@b.example");
    expect(wire).not.toContain("utm_source");
    expect(wire).not.toContain("$referrer");
    expect(wire).not.toContain("$current_url");
    expect(problems).toEqual([]);
  });
}

test("keeps only the referring hostname", async ({ page, analytics }) => {
  await page.goto("/", { referer: "https://news.ycombinator.com/item?id=123456" });
  const [pageview] = await waitForEvent(analytics, "$pageview");
  expect(pageview.properties.$referring_domain).toBe("news.ycombinator.com");
  expect(JSON.stringify(sentEvents(analytics))).not.toContain("123456");
});

test("stores no cookie and no web storage", async ({ page, analytics }) => {
  await page.goto("/");
  await waitForEvent(analytics, "$pageview");
  const stored = await page.evaluate(() => ({
    local: localStorage.length,
    session: sessionStorage.length,
    cookie: document.cookie,
  }));
  expect(stored).toEqual({ local: 0, session: 0, cookie: "" });
});

test("a Global Privacy Control signal turns analytics off", async ({ page, analytics }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "globalPrivacyControl", { value: true });
  });
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(500);
  expect(analytics).toEqual([]);
});

test("a docs link click reports docs_root and copying the brew command reports install_brew", async ({
  page,
  analytics,
  context,
}) => {
  await context.route("https://docs.mouthtype.app/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/html", body: "docs" }),
  );
  await stayOnDownloadPage(page);
  await page.goto("/download/");
  await waitForEvent(analytics, "$pageview");
  await page.evaluate(() => {
    document.addEventListener("click", (event) => event.preventDefault());
  });
  await page.locator('a[href="https://docs.mouthtype.app/"]').first().click();
  await page.evaluate(() => {
    const code = document.querySelector('[data-cta="install_brew"]');
    getSelection().selectAllChildren(code);
    document.dispatchEvent(new ClipboardEvent("copy", { bubbles: true }));
  });
  await expect
    .poll(
      () =>
        sentEvents(analytics)
          .filter((event) => event.event === "cta activated")
          .map((event) => event.properties.cta_id)
          .sort(),
      { timeout: 10000 },
    )
    .toEqual(["docs_root", "install_brew"]);
  for (const event of sentEvents(analytics).filter((e) => e.event === "cta activated")) {
    expect(event.properties).toMatchObject({
      schema_version: 1,
      site: "mouthtype",
      surface: "marketing",
      path: "/download",
    });
  }
});

test("the download button reports the download CTA", async ({ page, analytics }) => {
  await stayOnDownloadPage(page);
  await page.goto("/download/");
  await waitForEvent(analytics, "$pageview");
  await page.evaluate(() => {
    document.addEventListener("click", (event) => event.preventDefault());
  });
  await page.locator("[data-download]").click();
  const ctas = await waitForEvent(analytics, "cta activated");
  expect(ctas.map((event) => event.properties.cta_id)).toEqual(["download"]);
});
