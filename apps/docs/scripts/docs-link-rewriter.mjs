import { posix } from "node:path";

import { destToUrl } from "./docs-manifest.mjs";

const LINK = /(!?)\[([^\]]*)\]\(([^)\s]+)\)/g;
const EXTERNAL = /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i;

/** Map of repo-relative source path -> site URL, built from the manifest. */
export function buildUrlMap(pages) {
  return new Map(pages.map((page) => [page.src, destToUrl(page.dest)]));
}

/**
 * Rewrites relative Markdown links in one source file.
 * - Links to another synced doc become site URLs.
 * - Links to anything else in the repo (source files, workflows, directories)
 *   point at GitHub: blob/ for files, tree/ for directories.
 * - A relative link to a path that doesn't exist throws, so a typo fails the
 *   sync instead of shipping a dead GitHub URL.
 * - External URLs and in-page anchors are left alone.
 * Fenced code blocks are skipped.
 */
const GITHUB_BASE = "https://github.com/CodesWhat/mouthtype";

export function rewriteLinks(text, srcPath, urlMap, statPath = () => "file") {
  const srcDir = posix.dirname(srcPath);
  let inFence = false;

  return text
    .split("\n")
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) {
        return line;
      }
      return line.replace(LINK, (match, bang, label, target) => {
        if (bang || target.startsWith("#") || EXTERNAL.test(target)) {
          return match;
        }
        const hashIndex = target.indexOf("#");
        const pathPart = hashIndex === -1 ? target : target.slice(0, hashIndex);
        const fragment = hashIndex === -1 ? "" : target.slice(hashIndex);
        const resolved = posix.normalize(posix.join(srcDir, pathPart));
        const url = urlMap.get(resolved);
        if (url) {
          return `[${label}](${url}${fragment})`;
        }
        const clean = resolved.replace(/\/$/, "");
        const found = resolved.startsWith("..") ? null : statPath(clean);
        if (!found) {
          throw new Error(`${srcPath}: link "${target}" points at a missing file (${resolved})`);
        }
        const kind = pathPart.endsWith("/") || found === "dir" ? "tree" : "blob";
        return `[${label}](${GITHUB_BASE}/${kind}/main/${clean}${fragment})`;
      });
    })
    .join("\n");
}

/** Drops the leading H1 (the frontmatter title replaces it). */
export function stripLeadingH1(text) {
  return text.replace(/^\s*# [^\n]*\n+/, "");
}

export function frontmatter({ title, description }) {
  return `---\ntitle: ${JSON.stringify(title)}\ndescription: ${JSON.stringify(description)}\n---\n\n`;
}
