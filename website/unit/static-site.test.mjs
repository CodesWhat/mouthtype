import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const distDir = path.join(projectDir, "dist");
const deployment = JSON.parse(fs.readFileSync(path.join(projectDir, "vercel.json"), "utf8"));
const ORIGIN = "https://mouthtype.app";

// CI builds first and sets REQUIRE_DIST=1, so a missing build fails there instead of skipping.
const hasDist = fs.existsSync(distDir);
if (!hasDist && process.env.REQUIRE_DIST) {
  throw new Error("dist/ is missing; run `npm run build` before the static site test");
}
const skip = hasDist ? false : "no dist/ directory; run `npm run build` first";

function walk(dir) {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .flatMap((entry) =>
      entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)],
    );
}

// Routes in vercel.json that serve a path with no file in dist/ (redirects, and /releases files that
// publish-website.py adds at release time).
const routedPaths = deployment.routes
  .filter((route) => route.status || route.dest || route.src.startsWith("/releases/"))
  .map((route) => new RegExp(`^${route.src}$`));

function resolves(urlPath) {
  const target = path.join(distDir, decodeURIComponent(urlPath));
  if (!target.startsWith(distDir)) return false;
  if (fs.existsSync(target)) {
    return fs.statSync(target).isFile() || fs.existsSync(path.join(target, "index.html"));
  }
  return routedPaths.some((route) => route.test(urlPath));
}

function localPath(url) {
  if (url.startsWith("//")) return null;
  let parsed;
  try {
    parsed = new URL(url, ORIGIN);
  } catch {
    return null;
  }
  if (parsed.origin !== new URL(ORIGIN).origin) return null;
  if (!url.startsWith("/") && !url.startsWith(`${ORIGIN}/`) && url !== ORIGIN) return null;
  return parsed.pathname || null;
}

test("every sitemap.xml URL has a built file", { skip }, () => {
  const xml = fs.readFileSync(path.join(distDir, "sitemap.xml"), "utf8");
  const urls = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1]);
  assert.ok(urls.length > 0, "sitemap.xml lists no URLs");
  const missing = urls.filter((url) => {
    assert.ok(url.startsWith(`${ORIGIN}/`), `${url} is not on ${ORIGIN}`);
    const file = path.join(distDir, new URL(url).pathname);
    return !(
      (fs.existsSync(file) && fs.statSync(file).isFile()) ||
      fs.existsSync(path.join(file, "index.html"))
    );
  });
  assert.deepEqual(missing, []);
});

test("robots.txt points at the sitemap", { skip }, () => {
  const robots = fs.readFileSync(path.join(distDir, "robots.txt"), "utf8");
  const line = robots.split("\n").find((entry) => entry.startsWith("Sitemap:"));
  assert.equal(line?.slice("Sitemap:".length).trim(), `${ORIGIN}/sitemap.xml`);
  assert.ok(fs.existsSync(path.join(distDir, "sitemap.xml")));
});

test("every internal href and src in built pages resolves", { skip }, () => {
  const broken = [];
  for (const file of walk(distDir).filter((entry) => entry.endsWith(".html"))) {
    const html = fs.readFileSync(file, "utf8");
    for (const match of html.matchAll(/\s(?:href|src)="([^"]+)"/g)) {
      const urlPath = localPath(match[1].replaceAll("&amp;", "&"));
      if (urlPath && !resolves(urlPath)) {
        broken.push(`${urlPath} (in ${path.relative(distDir, file)})`);
      }
    }
  }
  assert.deepEqual(broken, []);
});

test("catch-all route sets HSTS, COOP and a CSP with script-src 'self'", () => {
  const catchAll = deployment.routes.find((route) => route.src === "/(.*)");
  assert.equal(catchAll.headers["Strict-Transport-Security"], "max-age=63072000");
  assert.equal(catchAll.headers["Cross-Origin-Opener-Policy"], "same-origin");
  assert.match(catchAll.headers["Content-Security-Policy"], /(^|; )script-src 'self'(;|$)/);
});
