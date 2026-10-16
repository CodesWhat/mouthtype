# Mouthtype website

The product website lives here, independently of the Swift app. Static HTML, CSS and a small browser module, built with Vite. Node 24 and npm are required.

From the repo root, install with `npm --prefix website ci`. Run `npm --prefix website run dev` for local development, `npm --prefix website run build` for production, and `npm --prefix website run preview` to inspect the build. Output is `website/dist/`.

## Vercel

Import this repository with **Root Directory** set to `website`, **Framework Preset** set to Vite and Node set to 24.x. The checked-in `vercel.json` provides the build command, `dist` output and response headers. The site needs no environment variables, backend or native app build. Use preview deployments for website branches; choose the production branch in Vercel when ready to publish. No Vercel project ID or deployment is assumed here.

## Design and behavior

White and soft grey surfaces, dark ink, muted pine actions, existing orange branding, and a custom lime text selection. One matched headline/tagline pair is chosen per page load. It stays fixed until the next load; no carousel, timer, animation or play/pause control. The Mac status is positioned in the hero's top right without adding a row. The right side has faint dots, with no circle.

Classic is the default. The hero switches between real Classic and Hi-Fi recording-pill assets, rendered directly from the app's current view classes. The hero runs a prepared speaking-versus-typing illustration once when it comes into view, then stops. Reduced motion shows the completed phrase immediately. The pace is illustrative, not a measured benchmark or live recording. The spoken/cleaned comparison is also a prepared example. The Fn hint is larger and separated from the pill; original pixel icons replace the numbered principles. Additional clear/toy concepts remain design studies and are not shown as shipped skins. The site does not access the microphone, clipboard or installed app. Private alpha status and current macOS/Apple Silicon requirements remain explicit. Other platforms can be added when supported.

## Assets

`public/assets/mouthtype-icon*.png` comes from `design/icon/AppIcon.iconset`. The pill PNGs are produced by the app's `ClassicPillView` and `HiFiPillView` using fixed example levels, a four-second clock, and a 4× offscreen render. On macOS, regenerate with `bash website/scripts/render-pill-assets.sh`. The script compiles the actual view sources into a temporary renderer, creates no window and cleans up the executable. It does not launch Mouthtype or change preferences. Generated PNGs are committed, so deployment and Linux CI do not need Swift or macOS.

The three benefit icons in `public/assets/benefit-*.svg` are original 16-grid pixel artwork, drawn for this site.

The self-hosted Instrument Serif, Instrument Sans and JetBrains Mono subsets retain their SIL Open Font Licenses alongside the WOFF2 files in `public/fonts/`.

## Checks

`npm --prefix website test` runs headless Chromium checks against a production build. Install the browser once with `npx --prefix website playwright install chromium` after installing dependencies. Run the build before tests. An existing compatible Chromium executable may be selected with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`.

Checks cover both headline choices and their stability over time/reload, real skin assets, the prepared cleanup comparison, platform placement, local anchors, images and responsive layouts at 1440, 768, 390 and 320px. CI builds and runs these checks independently of the native app.
