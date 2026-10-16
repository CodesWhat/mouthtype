import { chromium } from "@playwright/test";
import { mkdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const publicDir = new URL("../public/", import.meta.url);
const outputDir = new URL("social/", publicDir);
const inline = async (path, type) =>
  `data:${type};base64,${(await readFile(new URL(path, publicDir))).toString("base64")}`;
const [serif, italic, sans, mono, icon, pill] = await Promise.all([
  inline("fonts/instrument-serif-latin-400-normal.woff2", "font/woff2"),
  inline("fonts/instrument-serif-latin-400-italic.woff2", "font/woff2"),
  inline("fonts/instrument-sans-latin-wght-normal.woff2", "font/woff2"),
  inline("fonts/jetbrains-mono-latin-wght-normal.woff2", "font/woff2"),
  inline("assets/mouthtype-icon-large.png", "image/png"),
  inline("assets/classic-recording.png", "image/png"),
]);
const cards = [
  ["home", "SOFTWARE FOR SAYING THINGS", "Say it.<br>Keep <em>moving.</em>", "Local dictation. Your words, kept yours."],
  ["start", "GET STARTED", "Your first<br><em>words.</em>", "A key, a thought, and somewhere to put it."],
  ["docs", "DOCUMENTATION", "The useful<br><em>details.</em>", "Shortcuts, cleanup, and the everyday bits."],
  ["why-mouthtype", "WHY MOUTHTYPE", "A little less<br>in the <em>way.</em>", "Local speech recognition. Room for your voice."],
  ["compare", "FIND YOUR FIT", "Different tools.<br>Your <em>choice.</em>", "See where Mouthtype fits into your day."],
  ["apple-dictation", "MOUTHTYPE & APPLE DICTATION", "Built in.<br>Or built <em>for you.</em>", "Two ways to get your words onto the page."],
  ["wispr-flow", "MOUTHTYPE & WISPR FLOW", "Similar idea.<br>Different <em>flow.</em>", "A closer look at where the work happens."],
];
await mkdir(outputDir, { recursive: true });
const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
});
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  for (const [name, label, title, description] of cards) {
    await page.setContent(`<!doctype html><html lang="en"><head><meta charset="utf-8"><style>
      @font-face { font-family: Serif; src: url('${serif}'); }
      @font-face { font-family: Serif; font-style: italic; src: url('${italic}'); }
      @font-face { font-family: Sans; src: url('${sans}'); }
      @font-face { font-family: Mono; src: url('${mono}'); }
      * { box-sizing: border-box; } body { margin: 0; width: 1200px; height: 630px; background: #fff; color: #111827; }
      .brand { position: absolute; top: 48px; left: 62px; display: flex; align-items: center; gap: 16px; font: 50px Serif; letter-spacing: -2px; }
      .brand img { width: 55px; height: 55px; }
      .label { position: absolute; top: 169px; left: 66px; font: 13px Mono; letter-spacing: 2px; }
      h1 { position: absolute; left: 62px; top: 210px; margin: 0; width: 710px; font: 108px/1.02 Serif; letter-spacing: -2px; }
      .description { position: absolute; left: 66px; top: 465px; width: 700px; margin: 0; font: 23px/1.4 Sans; color: #5e6879; }
      .texture { position: absolute; top: 132px; right: 30px; width: 375px; height: 360px; background: radial-gradient(#b3bdb6 1px, transparent 1px) 0 0 / 23px 23px; opacity: .55; }
      .paper { position: absolute; right: 68px; top: 198px; width: 286px; height: 228px; padding: 30px; border: 1px solid #ccd2dc; border-radius: 9px; background: #f8f9fa; transform: rotate(3deg); }
      .paper p { margin: 0 0 22px; font: 48px/1 Serif; }
      .paper i { display: block; height: 1px; margin-top: 13px; background: #d7dce4; }
      .paper i:last-child { width: 70%; }
      .pill { position: absolute; right: 48px; top: 376px; width: 330px; height: auto; transform: rotate(-3deg); }
      footer { position: absolute; left: 66px; right: 66px; bottom: 43px; padding-top: 22px; border-top: 1px solid #cbd0d8; display: flex; justify-content: space-between; font: 13px Mono; letter-spacing: 1px; }
      .status { display: flex; gap: 10px; align-items: center; } .status b { width: 8px; height: 8px; border-radius: 50%; background: #ef8b43; }
    </style></head><body>
      <div class="brand"><img src="${icon}" alt="">mouthtype</div>
      <div class="label">${label}</div><h1>${title}</h1><p class="description">${description}</p>
      <div class="texture"></div><div class="paper"><p>Your<br><em>words.</em></p><i></i><i></i></div>
      <img class="pill" src="${pill}" alt="Mouthtype recording pill">
      <footer><span class="status"><b></b>LOCAL DICTATION FOR YOUR MAC</span><span>mouthtype.app</span></footer>
    </body></html>`);
    await page.evaluate(() => document.fonts.ready);
    await page.locator(".pill").evaluate((image) => image.decode());
    await page.locator(".brand img").evaluate((image) => image.decode());
    const fits = await page.locator("h1").evaluate((heading) =>
      heading.scrollWidth <= heading.clientWidth && heading.getBoundingClientRect().bottom < 465,
    );
    if (!fits) throw new Error(`Social card headline does not fit: ${name}`);
    await page.screenshot({ path: fileURLToPath(new URL(`${name}.png`, outputDir)) });
    console.log(`Rendered social/${name}.png (1200×630)`);
  }
} finally {
  await browser.close();
}
