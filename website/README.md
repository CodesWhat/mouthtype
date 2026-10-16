# Mouthtype website

The product website lives here, independently of the Swift app. Static HTML, CSS and a small browser module, built with Vite. Node 24 and npm are required.

From the repo root, install with `npm --prefix website ci`. Run `npm --prefix website run dev` for local development, `npm --prefix website run build` for production, and `npm --prefix website run preview` to inspect the build. Output is `website/dist/`.

## Vercel

Import this repository with **Root Directory** set to `website`, **Framework Preset** set to Vite and Node set to 24.x. The checked-in `vercel.json` provides the build command, `dist` output and response headers. The site needs no environment variables, backend or native app build. Use preview deployments for website branches; choose the production branch in Vercel when ready to publish. No Vercel project ID or deployment is assumed here.

## Design and behavior

White and soft grey surfaces, dark ink, muted pine actions, existing orange branding, and a custom lime text selection. One matched headline/tagline pair is chosen per page load. The headline stays fixed until the next load, with no carousel, timer or playback control. The Mac status is positioned in the hero's top right without adding a row. The right side has faint dots, with no circle.

Classic is the default. The hero switches between real Classic and Hi-Fi recording-pill assets, rendered directly from the app's current view classes. The hero loops a prepared speaking-versus-typing illustration through three phrases. Its paper, text lanes, pill and skin labels keep fixed geometry so changing a phrase or skin does not move the layout. Reduced motion shows a completed phrase without animation. The principles form a continuous rightward ticker with a static reduced-motion fallback. The pace is illustrative, not a measured benchmark or live recording. The spoken/cleaned comparison is also a prepared example. The Fn hint is larger and separated from the pill; original pixel icons replace the numbered principles. Additional clear/toy concepts remain design studies and are not shown as shipped skins. The site does not access the microphone, clipboard or installed app. Alpha status and current macOS/Apple Silicon requirements remain explicit. Other platforms can be added when supported.

## Getting started and comparisons

`/start/` is a short first-dictation guide. `/docs/` is a compact anchored reference for shortcuts, cleanup and tone, spellings and phrases, recovery, local data and permissions. `/why-mouthtype/` explains the product direction. `/compare/` links to `/compare/apple-dictation/` and `/compare/wispr-flow/`, with checked official sources and explicit tradeoffs. These are static Vite multipage entries using the existing brand, self-hosted fonts and a separate page stylesheet. They load no hero module, microphone feature, signup form or backend. Fumadocs is not installed.

The guide labels the distributed alpha.3 separately from newer source builds with Settings and per-app tone. The current download is the Mac alpha; no price or Linux release is implied. Comparison details were checked October 16, 2026; recheck the linked official documentation when updating them.

## App and source downloads

The homepage and getting-started guide link directly to `/download` for the Mac alpha and `/source` for the corresponding GPL-3.0 source archive. These are coordinator-managed deployment routes, not HTML pages or placeholder ZIPs. Route them only to the verified release artifact and matching source archive, then check the hosted redirects, response headers, archive bytes and signatures before publishing the UI. The static Vite preview does not provide these artifacts.

This UI slice preserves the existing `0.1.0-alpha.3` build notes and explicitly documents its manual-update behavior. Newer source Settings and per-app rules stay labelled separately. When a newer release is actually packaged, update those instructions together with its verified artifact, source archive and update feed. No built-in updater is claimed for alpha.3. For an updater-enabled release, document its HTTPS checks and archive downloads separately from local dictation: checks do not upload transcripts or audio, automatic checking needs consent, installation is user-initiated, and anonymous system profiling is not enabled by default.

The browser download tests intercept the two endpoints with clearly labelled attachment fixtures. They verify the UI and download behavior without fetching a large release or claiming that hosted artifacts have been published. Deployment verification owns the real downloads. The static internal-page checks exclude these two artifact endpoints.

## Sharing

The production domain is `https://mouthtype.app`. Every page includes a canonical URL, page-specific Open Graph and large-image Twitter card metadata in its static HTML. The seven committed PNG cards in `public/social/` are 1200×630 and use the existing fonts, icon and recording-pill asset. Sharing crawlers need no JavaScript or authenticated access.

Regenerate the cards with `npm --prefix website run render:social` after installing Playwright Chromium. The existing `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` override also applies to this renderer. It runs headlessly, embeds local assets and fonts, and creates no desktop window. Card generation is optional during deployment because the PNGs are committed.

## Assets

`public/assets/mouthtype-icon*.png` comes from `design/icon/AppIcon.iconset`. The pill PNGs are produced by the app's `ClassicPillView` and `HiFiPillView` using fixed example levels, a four-second clock, and a 4× offscreen render. On macOS, regenerate with `bash website/scripts/render-pill-assets.sh`. The script compiles the actual view sources into a temporary renderer, creates no window and cleans up the executable. It does not launch Mouthtype or change preferences. Generated PNGs are committed, so deployment and Linux CI do not need Swift or macOS.

The three benefit icons in `public/assets/benefit-*.svg` are original 16-grid pixel artwork, drawn for this site.

The self-hosted Instrument Serif, Instrument Sans and JetBrains Mono subsets retain their SIL Open Font Licenses alongside the WOFF2 files in `public/fonts/`.

## Checks

`npm --prefix website test` runs headless Chromium checks against a production build. Install the browser once with `npx --prefix website playwright install chromium` after installing dependencies. Run the build before tests. An existing compatible Chromium executable may be selected with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`.

Coverage includes both headline choices and their stability over time/reload, real skin assets, the prepared cleanup comparison, looping and reduced-motion hero pacing, fixed hero geometry, page-cache behavior, pill/instruction clearance, the principles ticker, platform placement, local anchors, images and responsive layouts. The page suite also checks direct loads/reloads, first-run and build-version guidance, linked task documentation, official comparison sources, mobile comparison readability and working internal links. CI builds and runs these checks independently of the native app.
