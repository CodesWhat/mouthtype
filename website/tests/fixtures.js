import { test as base, expect } from "@playwright/test";

export const INGESTION_ORIGIN = "https://e.codeswhat.com";

// Every page loads analytics, so no test may reach the real ingestion host. Requests are
// answered locally, and each test can read what it sent from `analytics`.
export const test = base.extend({
  analytics: [
    async ({ context }, use) => {
      const sent = [];
      await context.route(`${INGESTION_ORIGIN}/**`, (route) => {
        sent.push(route.request());
        return route.fulfill({
          status: 200,
          contentType: "application/json",
          headers: { "access-control-allow-origin": "*" },
          body: '{"status":1}',
        });
      });
      await use(sent);
    },
    { auto: true },
  ],
});

export { expect };
