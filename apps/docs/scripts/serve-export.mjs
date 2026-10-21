// Serves out/ with the headers from vercel.json applied, to check pages under the real CSP
// before deploying. Usage: node scripts/serve-export.mjs [port]. Not used in CI.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(projectDir, "out");
const config = JSON.parse(fs.readFileSync(path.join(projectDir, "vercel.json"), "utf8"));
const port = Number(process.argv[2] ?? 4010);

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".css": "text/css",
  ".woff2": "font/woff2",
  ".png": "image/png",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml",
};

// Vercel `source` patterns used here are exact paths or "<prefix>/(.*)".
function matches(source, pathname) {
  if (source.endsWith("(.*)")) return pathname.startsWith(source.slice(0, -"(.*)".length));
  return source === pathname;
}

function headersFor(pathname) {
  const out = {};
  for (const rule of config.headers) {
    if (!matches(rule.source, pathname)) continue;
    for (const { key, value } of rule.headers) out[key] = value;
  }
  return out;
}

http
  .createServer((req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname);
    let file = path.join(outDir, pathname);
    if (!file.startsWith(outDir)) return res.writeHead(403).end();
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) {
      if (!pathname.endsWith("/")) return res.writeHead(308, { Location: `${pathname}/` }).end();
      file = path.join(file, "index.html");
    }
    const found = fs.existsSync(file);
    const target = found ? file : path.join(outDir, "404.html");
    const body = fs.readFileSync(target);
    res.writeHead(found ? 200 : 404, {
      "Content-Type": TYPES[path.extname(target)] ?? "application/octet-stream",
      ...headersFor(pathname),
    });
    res.end(body);
  })
  .listen(port, () => console.log(`serving out/ on http://localhost:${port}`));
