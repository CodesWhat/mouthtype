import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(projectDir, "out");
const ORIGIN = "https://docs.mouthtype.app";

// CI runs the build first and sets REQUIRE_OUT=1, so a missing export fails there instead of skipping.
const hasOut = fs.existsSync(outDir);
if (!hasOut && process.env.REQUIRE_OUT) {
  throw new Error("out/ is missing; run `npm run build` before the static site test");
}
const skip = hasOut ? false : "no out/ directory; run `npm run build` first";

function walk(dir) {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .flatMap((entry) =>
      entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)],
    );
}

// trailingSlash: true exports /page/ as page/index.html; plain files (robots.txt, 404.html) also count.
function resolves(urlPath) {
  const target = path.join(outDir, decodeURIComponent(urlPath));
  if (!target.startsWith(outDir) || !fs.existsSync(target)) return false;
  return fs.statSync(target).isFile() || fs.existsSync(path.join(target, "index.html"));
}

test("every sitemap.xml URL has a built file", { skip }, () => {
  const xml = fs.readFileSync(path.join(outDir, "sitemap.xml"), "utf8");
  const urls = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1]);
  assert.ok(urls.length > 0, "sitemap.xml lists no URLs");
  const missing = urls.filter((url) => {
    assert.ok(url === ORIGIN || url.startsWith(`${ORIGIN}/`), `${url} is not on ${ORIGIN}`);
    return !resolves(new URL(url).pathname);
  });
  assert.deepEqual(missing, []);
});

test("robots.txt points at the sitemap", { skip }, () => {
  const robots = fs.readFileSync(path.join(outDir, "robots.txt"), "utf8");
  const line = robots.split("\n").find((entry) => entry.startsWith("Sitemap:"));
  assert.equal(line?.slice("Sitemap:".length).trim(), `${ORIGIN}/sitemap.xml`);
});

test("every internal href and src in exported pages resolves", { skip }, () => {
  const broken = [];
  for (const file of walk(outDir).filter((entry) => entry.endsWith(".html"))) {
    const html = fs.readFileSync(file, "utf8");
    for (const match of html.matchAll(/\s(?:href|src)="([^"]+)"/g)) {
      const url = match[1].replaceAll("&amp;", "&");
      if (url.startsWith("//")) continue;
      if (!url.startsWith("/") && !url.startsWith(`${ORIGIN}/`) && url !== ORIGIN) continue;
      let parsed;
      try {
        parsed = new URL(url, ORIGIN);
      } catch {
        continue;
      }
      if (parsed.origin !== new URL(ORIGIN).origin) continue;
      const urlPath = parsed.pathname;
      if (urlPath && !resolves(urlPath)) {
        broken.push(`${urlPath} (in ${path.relative(outDir, file)})`);
      }
    }
  }
  assert.deepEqual(broken, []);
});
