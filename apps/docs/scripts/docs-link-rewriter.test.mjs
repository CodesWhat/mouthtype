import assert from "node:assert/strict";
import { test } from "node:test";

import { buildUrlMap, frontmatter, rewriteLinks, stripLeadingH1 } from "./docs-link-rewriter.mjs";
import { pages } from "./docs-manifest.mjs";

const urlMap = buildUrlMap(pages);

test("rewrites a sibling doc link and keeps the fragment", () => {
  const out = rewriteLinks("See [settings](SETTINGS.md#health).", "docs/USAGE.md", urlMap);
  assert.equal(out, "See [settings](/reference/settings#health).");
});

test("resolves links from docs/guides", () => {
  const out = rewriteLinks("[fix](../TROUBLESHOOTING.md)", "docs/guides/dictating.md", urlMap);
  assert.equal(out, "[fix](/troubleshooting)");
});

test("folder index pages map to the folder URL", () => {
  const out = rewriteLinks("[go](getting-started.md)", "docs/guides/index.md", urlMap);
  assert.equal(out, "[go](/getting-started)");
});

test("unlinks repo paths that aren't docs", () => {
  const out = rewriteLinks("[Tests](../Tests/Foo.swift)", "docs/SECURITY.md", urlMap);
  assert.equal(out, "Tests");
});

test("leaves external links and anchors alone", () => {
  const text = "[a](https://mouthtype.app/docs/#x) [b](#top) [c](mailto:x@y.z)";
  assert.equal(rewriteLinks(text, "docs/USAGE.md", urlMap), text);
});

test("skips fenced code", () => {
  const text = "```\n[a](SETTINGS.md)\n```";
  assert.equal(rewriteLinks(text, "docs/USAGE.md", urlMap), text);
});

test("strips the leading H1 and builds frontmatter", () => {
  assert.equal(stripLeadingH1("# Title\n\nBody"), "Body");
  assert.equal(
    frontmatter({ title: 'A "b"', description: "c" }),
    '---\ntitle: "A \\"b\\""\ndescription: "c"\n---\n\n',
  );
});

test("every manifest source is unique", () => {
  assert.equal(new Set(pages.map((p) => p.src)).size, pages.length);
  assert.equal(new Set(pages.map((p) => p.dest)).size, pages.length);
});
