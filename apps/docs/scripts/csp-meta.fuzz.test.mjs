import assert from "node:assert/strict";
import crypto from "node:crypto";
import { test } from "node:test";

import fc from "fast-check";

import { cspForHTML, injectCspMeta, inlineScriptHashes } from "./csp-meta.mjs";

// Script bodies that cannot close the tag early or look like an opening tag.
const body = fc.string({ unit: "grapheme-ascii" }).filter((s) => !/<\/?script/i.test(s));
const hashOf = (s) => `'sha256-${crypto.createHash("sha256").update(s).digest("base64")}'`;
const META = /<meta\s+http-equiv=["']?Content-Security-Policy["']?[^>]*>/gi;

test("every inline script body gets its sha256 hash, sorted and unique", () => {
  fc.assert(
    fc.property(fc.array(body, { maxLength: 8 }), (bodies) => {
      const html = bodies.map((b) => `<script>${b}</script>`).join("<p>x</p>");
      const hashes = inlineScriptHashes(html);
      for (const b of bodies) assert.ok(hashes.includes(hashOf(b)));
      assert.deepEqual(hashes, [...new Set(hashes)].sort());
      assert.ok(hashes.length <= bodies.length);
    }),
  );
});

test("external scripts never contribute a hash", () => {
  fc.assert(
    fc.property(fc.webPath(), body, (src, b) => {
      const html = `<script src="${src}">${b}</script>`;
      assert.deepEqual(inlineScriptHashes(html), []);
    }),
  );
});

test("hashing ignores tag case and trailing whitespace in the end tag", () => {
  fc.assert(
    fc.property(
      body,
      fc.constantFrom("script", "SCRIPT", "Script"),
      fc.constantFrom("", " "),
      (b, tag, ws) => {
        assert.deepEqual(inlineScriptHashes(`<${tag}>${b}</${tag}${ws}>`), [hashOf(b)]);
      },
    ),
  );
});

test("cspForHTML always lists the page's hashes in script-src and locks down the rest", () => {
  fc.assert(
    fc.property(fc.array(body, { maxLength: 6 }), (bodies) => {
      const html = bodies.map((b) => `<script>${b}</script>`).join("");
      const directives = cspForHTML(html).split("; ");
      const scriptSrc = directives.find((d) => d.startsWith("script-src "));
      assert.ok(scriptSrc?.startsWith("script-src 'self'"));
      for (const b of bodies) assert.ok(scriptSrc.includes(hashOf(b)));
      assert.ok(!scriptSrc.includes("unsafe-inline"));
      assert.ok(directives.includes("default-src 'self'"));
      assert.ok(directives.includes("object-src 'none'"));
      assert.ok(!directives.some((d) => d.startsWith("frame-ancestors")));
    }),
  );
});

test("injectCspMeta puts exactly one meta first in head and is idempotent", () => {
  fc.assert(
    fc.property(
      fc.array(body, { maxLength: 5 }),
      fc.array(body, { maxLength: 2 }),
      (scripts, stale) => {
        const old = stale
          .map(
            (s) => `<meta http-equiv="Content-Security-Policy" content="${s.replace(/"/g, "")}"/>`,
          )
          .join("");
        const html = `<html><head>${old}${scripts.map((s) => `<script>${s}</script>`).join("")}</head><body></body></html>`;
        const once = injectCspMeta(html);
        assert.equal(once.match(META)?.length, 1);
        assert.ok(once.startsWith('<html><head><meta http-equiv="Content-Security-Policy"'));
        assert.equal(injectCspMeta(once), once);
      },
    ),
  );
});

test("injectCspMeta throws when there is no head", () => {
  fc.assert(
    fc.property(
      body.filter((s) => !/<head/i.test(s)),
      (b) => {
        assert.throws(
          () => injectCspMeta(`<html><body><script>${b}</script></body></html>`),
          /no <head>/,
        );
      },
    ),
  );
});
