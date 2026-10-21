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

test("points non-doc repo files at GitHub blob URLs", () => {
  const out = rewriteLinks("[Tests](../Tests/Foo.swift#L3)", "docs/SECURITY.md", urlMap);
  assert.equal(out, "[Tests](https://github.com/CodesWhat/mouthtype/blob/main/Tests/Foo.swift#L3)");
});

test("points directories at GitHub tree URLs", () => {
  const trailing = rewriteLinks("[src](../Sources/X/)", "docs/SECURITY.md", urlMap);
  assert.equal(trailing, "[src](https://github.com/CodesWhat/mouthtype/tree/main/Sources/X)");
  const detected = rewriteLinks("[web](../website)", "docs/USAGE.md", urlMap, (p) =>
    p === "website" ? "dir" : "file",
  );
  assert.equal(detected, "[web](https://github.com/CodesWhat/mouthtype/tree/main/website)");
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

test("a link to a missing file throws", () => {
  assert.throws(
    () => rewriteLinks("[x](nope.md)", "docs/USAGE.md", urlMap, () => null),
    /missing file/,
  );
});

test("every manifest page's links resolve against the real repo", async () => {
  const { readFileSync, statSync } = await import("node:fs");
  const { join } = await import("node:path");
  const repoRoot = join(import.meta.dirname, "..", "..", "..");
  const statPath = (p) => {
    try {
      return statSync(join(repoRoot, p)).isDirectory() ? "dir" : "file";
    } catch {
      return null;
    }
  };
  for (const page of pages) {
    rewriteLinks(readFileSync(join(repoRoot, page.src), "utf8"), page.src, urlMap, statPath);
  }
});
