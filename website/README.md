# Mouthtype website

The product website lives here, independently of the Swift app. Static HTML, CSS and a small browser module, built with Vite. Node 24 and npm are required.

From the repo root, install with `npm --prefix website ci`. Run `npm --prefix website run dev` for local development, `npm --prefix website run build` for production, and `npm --prefix website run preview` to inspect the build. Output is `website/dist/`.

## Vercel

Import this repository with **Root Directory** set to `website`, **Framework Preset** set to Vite and Node set to 24.x. The checked-in `vercel.json` provides the build command, `dist` output and response headers. The site needs no environment variables, backend or native app build. Use preview deployments for website branches; choose the production branch in Vercel when ready to publish. No Vercel project ID or deployment is assumed here.

## Design and behavior

White and soft grey surfaces, dark ink, muted pine actions, existing orange branding, and a custom lime text selection. One matched headline/tagline pair is chosen per page load. The headline stays fixed until the next load, with no carousel, timer or playback control. The Mac status is positioned in the hero's top right without adding a row. The right side has faint dots, with no circle.

Classic is the default. The hero switches between real Classic and Hi-Fi recording-pill assets, rendered directly from the app's current view classes. The hero loops a prepared speaking-versus-typing illustration through three phrases. Its paper, text lanes, pill and skin labels keep fixed geometry so changing a phrase or skin does not move the layout. Reduced motion shows a completed phrase without animation. The principles form a continuous rightward ticker with a static reduced-motion fallback. The pace is illustrative, not a measured benchmark or live recording. The spoken/cleaned comparison is also a prepared example. The Fn hint is larger and separated from the pill; original pixel icons replace the numbered principles. Additional clear/toy concepts remain design studies and are not shown as shipped skins. The site does not access the microphone, clipboard or installed app. Stable-release status and current macOS/Apple Silicon requirements remain explicit. Other platforms can be added when supported.

## Getting started and comparisons

`/start/` is a short Mac first-dictation guide. `/linux/` is the source-only experimental Linux installation path for the initial x86_64 Arch/Omarchy/Hyprland/PipeWire target, linked from the homepage, start, download and reference pages. It covers the Omarchy plugin, and `public/linux/agent-install.md` (served at `/linux/agent-install.md`) is a static ordered checklist for people and coding agents. It needs no JavaScript, microphone access, signup or backend. Physical desktop acceptance remains open. `/docs/` is a small redirect page to docs.mouthtype.app. Its same-origin `docs/redirect.js` maps each old anchor to the matching page and anchor there, and a meta refresh and plain link cover visitors without JavaScript. `/why-mouthtype/` explains the product direction. `/compare/` links to `/compare/apple-dictation/` and `/compare/wispr-flow/`, with checked official sources and explicit tradeoffs. These are static Vite multipage entries using the existing brand, self-hosted fonts and a separate page stylesheet. They load no hero module, microphone feature, signup form or backend. The Fumadocs docs site lives in `apps/docs` and deploys separately.

The guide describes 0.9.1 (build 24), including website tone, Basic selected-text preview, optional microphone priorities, completed-audio retention choices, synchronized microphone readiness, microphone selection, optional audio quieting/provisional words, single-file transcription, Settings, per-app tone and optional update checking. The current app download is the current stable release. The docs also explain experimental Linux source setup; no packaged Linux desktop release or price is implied. Comparison details were checked October 16, 2026; recheck the linked official documentation when updating them.

## App and source downloads

The homepage and getting-started guide link to `/download`, a landing page that requests the Mac DMG after five seconds only when browser platform metadata positively identifies a non-touch Mac. Linux, Windows, Android, iPad and unknown clients keep explicit platform links and do not start an automatic Mac download. Detection stays in memory and only controls that countdown; it does not redirect visitors, hide choices or establish OS/hardware compatibility. Its Download now link works immediately and without JavaScript, and cancels a pending automatic request. `/download/file` and `/source` redirect with HTTP 302 to the matching versioned 0.9.1 DMG/source under `/releases/0.9.1/`. The landing page, redirects and `/updates/appcast.xml` use `Cache-Control: no-store`; versioned releases remain immutable. The page stays visible after requesting the download and links to installation help. Vite preview serves the page but does not emulate Vercel’s file/source redirects; local browser timing tests use explicit file-response fixtures. Verify actual hosted downloads separately. Browser safety settings remain in force.

This copy targets `0.9.1` (build 24). Hold publication until the verified signed/notarized DMG and update ZIP, matching GPL source archive and signed update feed are staged at the configured paths. Verify the hosted redirects, cache headers, archive bytes, signatures and updater behavior before calling the release ready. Do not overwrite versioned release assets. License and readme files ship inside app Resources.

Alpha.1–3 users need one manual download and replacement to get the updater. Alpha.4 and later offer Check for Updates and optional automatic checking, with user-initiated installation. The reference distinguishes HTTPS update checks and archive downloads from local dictation: checks do not upload transcripts or audio, and anonymous system profiling is not enabled by default. Fresh-install, physical custom-key, broader paste and actual in-app installation checks remain prerelease test work.

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
