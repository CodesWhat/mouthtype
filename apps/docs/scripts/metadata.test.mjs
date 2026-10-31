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
  assert.match(xml, /<loc>https:\/\/docs.mouthtype.app/);
  assert.doesNotMatch(xml, /<lastmod>/);
});
