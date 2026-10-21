#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { buildUrlMap, frontmatter, rewriteLinks, stripLeadingH1 } from "./docs-link-rewriter.mjs";
import { folders, pages, rootPages } from "./docs-manifest.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const docsRoot = join(scriptDir, "..");
const repoRoot = join(docsRoot, "..", "..");

const targetDir = join(docsRoot, "content", "docs");
const tmpDir = join(docsRoot, "content", "docs.tmp");

const urlMap = buildUrlMap(pages);

// Build into a temp directory so a mid-run crash can't leave an empty docs site.
if (existsSync(tmpDir)) {
  rmSync(tmpDir, { recursive: true, force: true });
}
mkdirSync(tmpDir, { recursive: true });

for (const page of pages) {
  const srcFile = join(repoRoot, page.src);
  if (!existsSync(srcFile)) {
    console.error(`Missing docs source: ${page.src}`);
    process.exit(1);
  }

  const body = rewriteLinks(stripLeadingH1(readFileSync(srcFile, "utf8")), page.src, urlMap);
  const destFile = join(tmpDir, `${page.dest}.md`);
  mkdirSync(dirname(destFile), { recursive: true });
  writeFileSync(destFile, frontmatter(page) + body);
}

writeFileSync(
  join(tmpDir, "meta.json"),
  JSON.stringify({ title: "Mouthtype", pages: rootPages }, null, 2),
);

for (const [slug, meta] of Object.entries(folders)) {
  writeFileSync(join(tmpDir, slug, "meta.json"), JSON.stringify(meta, null, 2));
}

if (existsSync(targetDir)) {
  rmSync(targetDir, { recursive: true, force: true });
}
renameSync(tmpDir, targetDir);

console.log(`Synced ${pages.length} pages into content/docs`);
