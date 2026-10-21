import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildHeaders,
  cspForHTML,
  inlineScriptHashes,
  routeForOutputPath,
} from "./security-headers.mjs";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(projectDir, "out");
const vercelConfig = JSON.parse(fs.readFileSync(path.join(projectDir, "vercel.json"), "utf8"));

// CI runs the build first and sets REQUIRE_OUT=1, so a missing export fails there instead of skipping.
const hasOut = fs.existsSync(outDir);
if (!hasOut && process.env.REQUIRE_OUT) {
  throw new Error("out/ is missing; run `npm run build` before the CSP coverage test");
}
const skip = hasOut ? false : "no out/ directory; run `npm run build` first";

function pages(root = outDir) {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...pages(target));
    else if (target.endsWith(".html")) files.push(target);
  }
  return files;
}

function cspFor(source) {
  const entry = vercelConfig.headers.find((h) => h.source === source);
  return entry?.headers.find((h) => h.key === "Content-Security-Policy")?.value;
}

test("hashes inline scripts and ignores external ones", () => {
  const html = '<script src="/a.js"></script><script>alert(1)</script><SCRIPT >x</SCRIPT >';
  assert.equal(inlineScriptHashes(html).length, 2);
});

test("policy has no unsafe-inline or unsafe-eval in script-src", () => {
  const csp = cspForHTML("<script>1</script>");
  const scriptSrc = csp.split("; ").find((d) => d.startsWith("script-src"));
  assert.ok(scriptSrc);
  assert.doesNotMatch(scriptSrc, /unsafe-/);
  assert.match(csp, /frame-ancestors 'none'/);
});

test("HSTS has no includeSubDomains", () => {
  const all = vercelConfig.headers.flatMap((h) => h.headers);
  const hsts = all.find((h) => h.key === "Strict-Transport-Security");
  assert.ok(hsts);
  assert.doesNotMatch(hsts.value, /includeSubDomains/i);
});

test("committed vercel.json headers match a fresh build of out/", { skip }, () => {
  assert.deepEqual(vercelConfig.headers, buildHeaders(outDir));
});

test("every page's inline scripts are covered by its CSP hashes", { skip }, () => {
  const files = pages();
  assert.ok(files.length > 20, "expected the full docs export");
  for (const file of files) {
    const relative = path.relative(outDir, file);
    const route = routeForOutputPath(relative);
    const source = route ?? "/(.*)";
    if (!route && relative !== "404.html") continue;
    const csp = cspFor(source);
    assert.ok(csp, `no CSP header for ${source}`);
    const scriptSrc = csp.split("; ").find((d) => d.startsWith("script-src")) ?? "";
    assert.doesNotMatch(scriptSrc, /unsafe-inline/, `${source} allows unsafe-inline scripts`);
    for (const hash of inlineScriptHashes(fs.readFileSync(file, "utf8"))) {
      assert.ok(scriptSrc.includes(hash), `${source}: inline script ${hash} is not in script-src`);
    }
  }
});
