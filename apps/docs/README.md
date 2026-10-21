# Mouthtype docs site

Fumadocs on Next 16. Content lives in the repo `docs/` folder (and two Linux READMEs under `tools/`). `scripts/sync-docs.mjs` copies it into `content/docs/` with frontmatter, using the page map in `scripts/docs-manifest.mjs`. `content/docs/` is generated and gitignored.

```sh
cd apps/docs
npm install
npm run dev      # syncs docs, serves http://localhost:3000
npm run build
npm run check    # biome
npm run test:scripts
```

Set `DOCS_BASE_PATH=/docs` to serve under a sub-path, and `NEXT_PUBLIC_SITE_URL` for canonical URLs. Nothing here is deployed yet.
