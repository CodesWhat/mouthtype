import { expect, test } from "@playwright/test";

const GUIDE = "/dictating/";

// Fails any test that logs a console error, throws a page error or loads a failed request.
test.beforeEach(({ page }) => {
  const problems = [];
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  // ERR_ABORTED is a navigation or link prefetch cancelled on purpose, not a failure.
  page.on("requestfailed", (request) => {
    const reason = request.failure()?.errorText ?? "";
    if (!/ABORTED|cancelled|aborted/i.test(reason))
      problems.push(`requestfailed: ${request.url()} ${reason}`);
  });
  page.problems = problems;
});

test.afterEach(({ page }) => {
  expect(page.problems).toEqual([]);
});

test("home page renders with canonical and og:image", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
    "href",
    "https://docs.mouthtype.app/",
  );
  await expect(page.locator('meta[property="og:image"]')).toHaveAttribute(
    "content",
    /^https:\/\/mouthtype\.app\/social\/.+\.png$/,
  );
});

test("a guide renders with canonical and og:image", async ({ page }) => {
  await page.goto(GUIDE);
  await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
    "href",
    `https://docs.mouthtype.app${GUIDE}`,
  );
  await expect(page.locator('meta[property="og:image"]')).toHaveAttribute(
    "content",
    /^https:\/\/mouthtype\.app\/social\/.+\.png$/,
  );
});

test("sidebar navigation reaches a guide from the home page", async ({ page, isMobile }) => {
  test.skip(isMobile, "the sidebar is a drawer on small viewports; covered by the phone test");
  await page.goto("/");
  await page.getByRole("complementary").locator(`a[href="${GUIDE}"]`).click();
  await expect(page).toHaveURL(new RegExp(`${GUIDE}$`));
  await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
});

test.describe("phone viewport", () => {
  test.use({ viewport: { width: 390, height: 780 } });

  test("the sidebar drawer opens, navigates and closes", async ({ page }) => {
    await page.goto("/");
    const drawer = page.locator("#nd-sidebar-mobile");
    const link = drawer.locator(`a[href="${GUIDE}"]`);
    const open = page.getByRole("button", { name: "Open Sidebar" }).first();
    await expect(drawer).toHaveAttribute("data-state", "closed");

    await open.click();
    await expect(drawer).toHaveAttribute("data-state", "open");
    await expect(link).toBeInViewport();

    await drawer.getByRole("button", { name: "Close Sidebar" }).click();
    await expect(drawer).toHaveAttribute("data-state", "closed");
    await expect(link).not.toBeInViewport();

    await open.click();
    await link.click();
    await expect(page).toHaveURL(new RegExp(`${GUIDE}$`));
    await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
    await expect(open).toBeVisible();
  });

  test("the page does not scroll sideways", async ({ page }) => {
    await page.goto(GUIDE);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
      true,
    );
  });
});

test("search opens, finds a page and closes", async ({ page }) => {
  await page.goto("/");
  await page
    .getByRole("button", { name: /search/i })
    .locator("visible=true")
    .first()
    .click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await dialog.getByRole("combobox", { name: "Search" }).fill("dictation");
  await expect(dialog.getByRole("option").first()).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
});
