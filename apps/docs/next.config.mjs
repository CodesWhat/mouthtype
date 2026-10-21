import { createMDX } from "fumadocs-mdx/next";

const withMDX = createMDX();

// The site is a static export served from the root of docs.mouthtype.app.
// DOCS_BASE_PATH=/docs is still honored for a sub-path mount, but it is not the default.
const basePath = process.env.DOCS_BASE_PATH || undefined;

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  // Keeps the exported inline bootstrap scripts deterministic, so the per-page CSP hashes
  // in vercel.json only change when page content does. Static assets stay content-hashed.
  generateBuildId: async () => "mouthtype-docs-static",
  poweredByHeader: false,
  basePath,
  // Client code needs the prefix for URLs Next does not rewrite (search API, static assets).
  env: { NEXT_PUBLIC_DOCS_BASE_PATH: basePath ?? "" },
  turbopack: {
    root: import.meta.dirname,
  },
};

export default withMDX(nextConfig);
