import { createMDX } from "fumadocs-mdx/next";

const withMDX = createMDX();

// Set DOCS_BASE_PATH=/docs when the site is served under mouthtype.app/docs
// instead of its own host. Leave it unset for docs.mouthtype.app.
const basePath = process.env.DOCS_BASE_PATH || undefined;

/** @type {import('next').NextConfig} */
const nextConfig = {
  poweredByHeader: false,
  basePath,
  turbopack: {
    root: import.meta.dirname,
  },
};

export default withMDX(nextConfig);
