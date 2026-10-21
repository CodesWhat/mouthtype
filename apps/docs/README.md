# Mouthtype docs site

Fumadocs on Next 16, built as a static export (`output: "export"`) for docs.mouthtype.app, served from the site root. Content lives in the repo `docs/` folder (and two Linux READMEs under `tools/`). `scripts/sync-docs.mjs` copies it into `content/docs/` with frontmatter, using the page map in `scripts/docs-manifest.mjs`. `content/docs/` is generated and gitignored. A relative link to a file that doesn't exist fails the sync.

```sh
cd apps/docs
npm install
npm run dev      # syncs docs, serves http://localhost:3000
npm run build    # static export to out/, then injects a per-page CSP meta tag into each HTML file
npm run check    # biome
npm run test:scripts
node scripts/serve-export.mjs   # serve out/ with the vercel.json headers applied
```

## CSP

`scripts/csp-meta.mjs` runs after `next build`. It sha256-hashes every inline script on each page and injects a `<meta http-equiv="Content-Security-Policy">` as the first child of `<head>` (`script-src 'self'` plus those hashes, no `'unsafe-inline'`). `vercel.json` holds one static header on `/(.*)` with the page-independent directives and `frame-ancestors`, which a meta tag can't carry. It deliberately has no `default-src` or `script-src`: browsers enforce the intersection of header and meta, so any script policy there would block the hashed inline scripts. Nothing in `vercel.json` depends on content, so docs edits don't touch it. `scripts/csp-coverage.test.mjs` checks both halves against a fresh build.

## Config

`NEXT_PUBLIC_SITE_URL` sets canonical URLs (default `https://docs.mouthtype.app`). `DOCS_BASE_PATH=/docs` serves under a sub-path, but the CSP route sources in `vercel.json` assume the root, so don't use it for a deploy without reworking them. Nothing here is deployed by this repo.
