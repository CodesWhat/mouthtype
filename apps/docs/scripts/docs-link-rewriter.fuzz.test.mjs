import assert from "node:assert/strict";
import { test } from "node:test";

import fc from "fast-check";
import { frontmatter, rewriteLinks, stripLeadingH1 } from "./docs-link-rewriter.mjs";
import { destToUrl } from "./docs-manifest.mjs";

const seg = fc.stringMatching(/^[a-z][a-z0-9-]{0,8}$/).filter((s) => s !== "index");
const dest = fc.array(seg, { minLength: 1, maxLength: 4 }).map((p) => p.join("/"));

test("destToUrl always yields a rooted path and drops a trailing index", () => {
  fc.assert(
    fc.property(dest, fc.boolean(), (d, withIndex) => {
      const url = destToUrl(withIndex ? `${d}/index` : d);
      assert.equal(url, `/${d}`);
      assert.ok(!url.endsWith("/index"));
    }),
  );
  assert.equal(destToUrl("index"), "/");
});

test("text without relative links passes through unchanged", () => {
  const safe = fc
    .array(
      fc.constantFrom(
        "plain text",
        "# heading",
        "![img](rel/a.png)",
        "[x](#frag)",
        "[e](https://a.dev/x)",
        "[m](mailto:a@b.c)",
        "",
      ),
    )
    .map((l) => l.join("\n"));
  fc.assert(
    fc.property(safe, (text) => {
      assert.equal(rewriteLinks(text, "docs/a.md", new Map()), text);
    }),
  );
});

test("links inside fenced code blocks are never rewritten or validated", () => {
  fc.assert(
    fc.property(seg, (s) => {
      const text = `\`\`\`\n[a](./${s}-missing.md)\n\`\`\``;
      assert.equal(
        rewriteLinks(text, "docs/a.md", new Map(), () => null),
        text,
      );
    }),
  );
});

test("a link to a synced doc becomes its site URL and keeps the fragment", () => {
  fc.assert(
    fc.property(dest, seg, (d, frag) => {
      const map = new Map([[`docs/${d}.md`, destToUrl(d)]]);
      const out = rewriteLinks(`[l](./${d}.md#${frag})`, "docs/a.md", map);
      assert.equal(out, `[l](/${d}#${frag})`);
    }),
  );
});

test("a link to a missing path throws, an existing one points at GitHub", () => {
  fc.assert(
    fc.property(dest, (d) => {
      const text = `[l](../${d}.js)`;
      assert.throws(() => rewriteLinks(text, "docs/a.md", new Map(), () => null), /missing file/);
      const out = rewriteLinks(text, "docs/a.md", new Map(), () => "file");
      assert.equal(out, `[l](https://github.com/CodesWhat/mouthtype/blob/main/${d}.js)`);
    }),
  );
});

test("links escaping the repo root are rejected", () => {
  fc.assert(
    fc.property(fc.integer({ min: 2, max: 6 }), seg, (n, s) => {
      const up = "../".repeat(n);
      assert.throws(
        () => rewriteLinks(`[l](${up}${s}.md)`, "a.md", new Map(), () => "file"),
        /missing file/,
      );
    }),
  );
});

test("stripLeadingH1 removes only a leading H1", () => {
  const title = fc.stringMatching(/^[A-Za-z0-9 ]{1,20}$/);
  fc.assert(
    fc.property(title, fc.stringMatching(/^[a-z][a-z ]{0,20}$/), (t, rest) => {
      assert.equal(stripLeadingH1(`# ${t}\n\n${rest}`), rest);
      assert.equal(stripLeadingH1(rest), rest);
    }),
  );
});

test("frontmatter round-trips arbitrary title and description through JSON", () => {
  fc.assert(
    fc.property(fc.string(), fc.string(), (title, description) => {
      const out = frontmatter({ title, description });
      const lines = out.split("\n");
      assert.equal(lines[0], "---");
      assert.equal(JSON.parse(lines[1].slice("title: ".length)), title);
      assert.equal(JSON.parse(lines[2].slice("description: ".length)), description);
      assert.equal(lines[3], "---");
    }),
  );
});
