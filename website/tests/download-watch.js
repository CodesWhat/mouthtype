import { expect } from "@playwright/test";

// Playwright's WebKit never emits "download" for a route.fulfill response carrying
// Content-Disposition: attachment (checked against a real server, where it does fire).
// The site behaves the same in both cases, so on WebKit the fixture request to
// /download/file stands in for the download event. Other engines use the real event.
export function watchDownloads(page, browserName) {
  const viaRequest = browserName === "webkit";
  const starts = [];
  page.on(viaRequest ? "request" : "download", (item) => {
    if (viaRequest && new URL(item.url()).pathname !== "/download/file") return;
    starts.push(item);
  });
  return {
    starts,
    async next() {
      const seen = starts.length;
      await expect.poll(() => starts.length).toBeGreaterThan(seen);
      return starts[starts.length - 1];
    },
    filenameOf: (item) => (viaRequest ? undefined : item.suggestedFilename()),
  };
}
