import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { cspForHTML, htmlFiles, injectCspMeta, inlineScriptHashes } from "./csp-meta.mjs";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(projectDir, "out");
const vercelConfig = JSON.parse(fs.readFileSync(path.join(projectDir, "vercel.json"), "utf8"));

// CI runs the build first and sets REQUIRE_OUT=1, so a missing export fails there instead of skipping.
const hasOut = fs.existsSync(outDir);
if (!hasOut && process.env.REQUIRE_OUT) {
  throw new Error("out/ is missing; run `npm run build` before the CSP coverage test");
}
const skip = hasOut ? false : "no out/ directory; run `npm run build` first";

function directive(csp, name) {
  return csp.split("; ").find((d) => d === name || d.startsWith(`${name} `));
}

function headerCsp() {
  const all = vercelConfig.headers.filter((h) => h.source === "/(.*)").flatMap((h) => h.headers);
  return all.find((h) => h.key === "Content-Security-Policy")?.value;
}

test("hashes inline scripts and ignores external ones", () => {
  const html = '<script src="/a.js"></script><script>alert(1)</script><SCRIPT >x</SCRIPT >';
  assert.equal(inlineScriptHashes(html).length, 2);
});

test("meta policy has no unsafe-inline or unsafe-eval in script-src", () => {
  const scriptSrc = directive(cspForHTML("<script>1</script>"), "script-src");
  assert.ok(scriptSrc);
  assert.doesNotMatch(scriptSrc, /unsafe-/);
});

test("injection puts the meta first in head and is idempotent", () => {
  const html = '<html><head><meta charSet="utf-8"/><script>1</script></head><body></body></html>';
  const once = injectCspMeta(html);
  assert.ok(once.indexOf("Content-Security-Policy") < once.indexOf("<script>"));
  assert.ok(once.startsWith('<html><head><meta http-equiv="Content-Security-Policy"'));
  assert.equal(injectCspMeta(once), once);
});

test("header carries frame-ancestors and nothing that constrains scripts", () => {
  const csp = headerCsp();
  assert.ok(csp, "no static Content-Security-Policy header on /(.*)");
  assert.match(csp, /frame-ancestors 'none'/);
  // The header can't list per-page hashes, so a script-src or default-src there would block
  // them. The meta policy owns both directives.
  assert.equal(directive(csp, "script-src"), undefined);
  assert.equal(directive(csp, "default-src"), undefined);
});

test("header script-src has no unsafe-inline", () => {
  const scriptSrc = directive(headerCsp(), "script-src") ?? "";
  assert.doesNotMatch(scriptSrc, /unsafe-inline/);
});

test("vercel.json has no per-page CSP rules", () => {
  const perPage = vercelConfig.headers.filter(
    (h) => h.source !== "/(.*)" && h.headers.some((x) => x.key === "Content-Security-Policy"),
  );
  assert.deepEqual(perPage, []);
});

test("HSTS has no includeSubDomains", () => {
  const all = vercelConfig.headers.flatMap((h) => h.headers);
  const hsts = all.find((h) => h.key === "Strict-Transport-Security");
  assert.ok(hsts);
  assert.doesNotMatch(hsts.value, /includeSubDomains/i);
});

test("every page has a meta CSP covering all its inline scripts", { skip }, () => {
  const files = htmlFiles(outDir);
  assert.ok(files.length > 20, "expected the full docs export");
  for (const file of files) {
    const relative = path.relative(outDir, file);
    const html = fs.readFileSync(file, "utf8");
    const metas = [
      ...html.matchAll(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]*)"\s*\/?>/gi),
    ];
    assert.equal(metas.length, 1, `${relative}: expected exactly one CSP meta`);
    const metaAt = metas[0].index;
    const firstScript = html.search(/<script[\s>]/i);
    assert.ok(
      firstScript === -1 || metaAt < firstScript,
      `${relative}: CSP meta must precede the first script`,
    );
    assert.ok(metaAt > html.search(/<head[\s>]/i), `${relative}: CSP meta must be inside head`);
    const scriptSrc = directive(metas[0][1], "script-src") ?? "";
    assert.doesNotMatch(scriptSrc, /unsafe-/, `${relative}: script-src allows unsafe-*`);
    for (const hash of inlineScriptHashes(html)) {
      assert.ok(
        scriptSrc.includes(hash),
        `${relative}: inline script ${hash} not in meta script-src`,
      );
    }
  }
});
