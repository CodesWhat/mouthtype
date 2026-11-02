import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { htmlFiles } from "./csp-meta.mjs";

const out = fileURLToPath(new URL("../out/", import.meta.url));
const hasOut = fs.existsSync(out);
if (!hasOut && process.env.REQUIRE_OUT)
  throw new Error("Build docs before checking exported metadata");
const skip = hasOut ? false : "Build docs first";

test("exported docs include the existing documentation social card", { skip }, () => {
  let checked = 0;
  for (const file of htmlFiles(out)) {
    const html = fs.readFileSync(file, "utf8");
    if (!html.includes('rel="canonical"')) continue;
    assert.match(
      html,
      /property="og:image" content="https:\/\/mouthtype.app\/social\/docs.png"/,
      path.relative(out, file),
    );
    checked += 1;
  }
  assert.ok(checked > 0);
});

test("sitemap avoids presenting deployment dates as content modifications", { skip }, () => {
  const xml = fs.readFileSync(path.join(out, "sitemap.xml"), "utf8");
  const canonicals = new Set();
  for (const file of htmlFiles(out)) {
    const html = fs.readFileSync(file, "utf8");
    for (const match of html.matchAll(/<link rel="canonical" href="([^"]+)"/g))
      canonicals.add(new URL(match[1]).href);
  }
  const locations = Array.from(xml.matchAll(/<loc>([^<]+)<\/loc>/g), (match) => match[1]);
  assert.ok(locations.length > 0);
  for (const location of locations)
    assert.ok(
      canonicals.has(new URL(location).href),
      `Sitemap URL lacks an exported canonical: ${location}`,
    );
  assert.doesNotMatch(xml, /<lastmod>/);
});
