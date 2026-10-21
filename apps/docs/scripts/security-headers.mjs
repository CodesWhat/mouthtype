// Postbuild for the static export. Hashes every inline script on every page and writes a
// per-page Content-Security-Policy into vercel.json, so script-src needs no 'unsafe-inline'.
// Modelled on portwing/website/scripts/security-headers.mjs, but it writes vercel.json
// headers instead of a Build Output API config, since Vercel builds this project from git.
//
// vercel.json is committed. Run `npm run build` after any content change that moves an
// inline script, and commit the result. scripts/csp-coverage.test.mjs fails when it's stale.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_FILE = fileURLToPath(import.meta.url);
const PROJECT_DIR = path.resolve(path.dirname(SCRIPT_FILE), "..");

const COMMON_HEADERS = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  {
    key: "Permissions-Policy",
    value: "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
  },
  { key: "Strict-Transport-Security", value: "max-age=63072000" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
];

const IMMUTABLE = [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }];

export function inlineScriptHashes(html) {
  const hashes = new Set();
  // The end tag mirrors the start tag and matching is case-insensitive, because that is what
  // an HTML parser accepts. A form this misses gets no hash and the CSP blocks a script the
  // page needs: silent at build time, fatal in the browser.
  for (const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script(?:\s[^>]*)?>/gi)) {
    if (/\ssrc=/i.test(match[0].slice(0, match[0].indexOf(">")))) continue;
    const digest = crypto.createHash("sha256").update(match[1]).digest("base64");
    hashes.add(`'sha256-${digest}'`);
  }
  return [...hashes].sort();
}

export function cspForHTML(html) {
  return [
    "default-src 'self'",
    `script-src 'self' ${inlineScriptHashes(html).join(" ")}`.trim(),
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "form-action 'none'",
  ].join("; ");
}

/** "dictating/index.html" -> "/dictating/", "index.html" -> "/". null for non-page files. */
export function routeForOutputPath(relative) {
  const rel = relative.replaceAll("\\", "/");
  if (rel === "index.html") return "/";
  if (rel.endsWith("/index.html")) return `/${rel.slice(0, -"index.html".length)}`;
  return null;
}

function htmlFiles(root) {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...htmlFiles(target));
    else if (target.endsWith(".html")) files.push(target);
  }
  return files.sort();
}

/** The full `headers` array for vercel.json. */
export function buildHeaders(outputDir) {
  const headers = [];
  // 404.html is served for any unmatched path, so its policy is the catch-all. Specific
  // routes come after it and override the same header.
  const notFound = path.join(outputDir, "404.html");
  const fallbackCsp = fs.existsSync(notFound)
    ? cspForHTML(fs.readFileSync(notFound, "utf8"))
    : cspForHTML("");
  headers.push({
    source: "/(.*)",
    headers: [...COMMON_HEADERS, { key: "Content-Security-Policy", value: fallbackCsp }],
  });
  for (const file of htmlFiles(outputDir)) {
    const relative = path.relative(outputDir, file);
    const route = routeForOutputPath(relative);
    if (!route) continue;
    headers.push({
      source: route,
      headers: [
        { key: "Content-Security-Policy", value: cspForHTML(fs.readFileSync(file, "utf8")) },
      ],
    });
  }
  headers.push({ source: "/_next/static/(.*)", headers: IMMUTABLE });
  headers.push({ source: "/fonts/(.*)", headers: IMMUTABLE });
  return headers;
}

export function renderVercelConfig(existing, outputDir) {
  return `${JSON.stringify({ ...existing, headers: buildHeaders(outputDir) }, null, 2)}\n`;
}

function main() {
  const outputDir = path.join(PROJECT_DIR, "out");
  if (!fs.existsSync(outputDir)) {
    throw new Error(`static output not found: ${outputDir}; run next build first`);
  }
  const configPath = path.join(PROJECT_DIR, "vercel.json");
  const existing = JSON.parse(fs.readFileSync(configPath, "utf8"));
  fs.writeFileSync(configPath, renderVercelConfig(existing, outputDir));
  console.log("Wrote per-page CSP headers to vercel.json");
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_FILE) {
  main();
}
