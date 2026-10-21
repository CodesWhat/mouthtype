// Single source of truth for how repo Markdown maps into the docs site tree.
// `src` is relative to the repo root. `dest` is the page path under content/docs
// (no extension). Titles and descriptions live here so the source files keep
// their plain GitHub-readable form with no frontmatter.

export const pages = [
  {
    src: "docs/guides/index.md",
    dest: "index",
    title: "Mouthtype docs",
    description: "Local dictation for Apple Silicon Macs. Guides, reference and troubleshooting.",
  },
  {
    src: "docs/guides/getting-started.md",
    dest: "getting-started/index",
    title: "Getting started",
    description:
      "Install Mouthtype, allow Microphone and Accessibility, and make your first dictation with Fn.",
  },
  {
    src: "docs/READ-ME.md",
    dest: "getting-started/install-notes",
    title: "Install notes and release notes",
    description: "The install notes that ship with the app, plus what changed in each release.",
  },
  {
    src: "docs/guides/dictating.md",
    dest: "dictating",
    title: "Dictating",
    description:
      "Hold or hands-free, shortcuts, live words, recording sounds, quiet other audio and recovery.",
  },
  {
    src: "docs/guides/cleanup-and-style.md",
    dest: "cleanup-and-style/index",
    title: "Cleanup and Style",
    description: "Cleanup levels, tone per context, and app and website rules.",
  },
  {
    src: "docs/WRITING-TOOLS.md",
    dest: "cleanup-and-style/writing-tools",
    title: "Writing tools reference",
    description: "Website rules, browser eligibility and microphone priority details.",
  },
  {
    src: "docs/guides/dictionary.md",
    dest: "dictionary",
    title: "Dictionary",
    description: "Saved words, heard forms, suggestions and the Import CSV format.",
  },
  {
    src: "docs/guides/transforms.md",
    dest: "transforms",
    title: "Transforms",
    description:
      "Spoken phrases with date and clipboard placeholders, and Transform Selection from the menu bar.",
  },
  {
    src: "docs/FILE-TRANSCRIPTION.md",
    dest: "transcribe-audio-files",
    title: "Transcribe audio files",
    description: "Turn one WAV, AIFF or M4A file into raw text, entirely on your Mac.",
  },
  {
    src: "docs/guides/automation.md",
    dest: "automation/index",
    title: "Automation",
    description: "The mouthtype:// URL scheme, the mouthtype command and the automation switch.",
  },
  {
    src: "docs/AUTOMATION.md",
    dest: "automation/url-scheme-and-cli",
    title: "URL scheme and command reference",
    description: "Every URL, page name, ordering rule and exit code.",
  },
  {
    src: "docs/guides/editor-hints.md",
    dest: "editor-hints",
    title: "Editor hints",
    description: "Optional code names from VS Code, Cursor, Xcode and terminals for one take.",
  },
  {
    src: "docs/guides/appearance.md",
    dest: "appearance",
    title: "Appearance",
    description: "Pill styles, sizes, fonts and the accessibility settings that change them.",
  },
  {
    src: "docs/guides/privacy-and-data.md",
    dest: "privacy-and-data/index",
    title: "Privacy and data",
    description: "Where your data lives, how long it's kept and what uses the network.",
  },
  {
    src: "docs/AUDIO-RETENTION.md",
    dest: "privacy-and-data/saved-audio",
    title: "Saved audio",
    description: "How long Mouthtype keeps completed recordings, and what is never pruned.",
  },
  {
    src: "docs/TROUBLESHOOTING.md",
    dest: "troubleshooting",
    title: "Troubleshooting",
    description: "Fixes for permissions, Fn, models, paste problems, recovery and updates.",
  },
  {
    src: "docs/guides/linux.md",
    dest: "linux/index",
    title: "Linux",
    description: "Experimental, source-only Linux support. There is no supported release.",
  },
  {
    src: "tools/linux-desktop/README.md",
    dest: "linux/linux-desktop-setup",
    title: "Linux desktop setup and testing",
    description: "Install and test the experimental Linux daemon and CLI.",
  },
  {
    src: "tools/omarchy-plugin/README.md",
    dest: "linux/linux-omarchy-plugin",
    title: "Omarchy plugin",
    description: "A bar menu, floating pill and shortcut choice for Omarchy.",
  },
  {
    src: "docs/SETTINGS.md",
    dest: "reference/settings",
    title: "Settings",
    description: "Every page of the Mouthtype window and the Settings modal.",
  },
  {
    src: "docs/SPOKEN-COMMANDS.md",
    dest: "reference/spoken-commands",
    title: "Spoken commands",
    description: "Punctuation, layout and list commands, and how counted lists work.",
  },
  {
    src: "docs/KNOWN-LIMITS.md",
    dest: "reference/known-limits",
    title: "Known limits",
    description: "What the current release doesn't promise.",
  },
  {
    src: "docs/SECURITY.md",
    dest: "reference/security",
    title: "Security",
    description: "Implemented controls, their limits and remaining assurance work.",
  },
  {
    src: "docs/USAGE.md",
    dest: "reference/usage-overview",
    title: "Usage overview",
    description: "The long-form overview of the Mac app, from install to data.",
  },
  {
    src: "docs/RELEASE-READINESS.md",
    dest: "reference/release-readiness",
    title: "Release readiness",
    description: "What was and wasn't verified on a device for the current release.",
  },
  {
    src: "docs/RELEASING.md",
    dest: "maintainers/releasing",
    title: "Releasing",
    description: "How a Mac prerelease is built, signed, notarized and staged.",
  },
  {
    src: "docs/MAC-EVALUATIONS.md",
    dest: "maintainers/mac-evaluations",
    title: "Mac daily-use evaluations",
    description: "The synthetic-speech evaluation script and its corpus.",
  },
];

// Sidebar order. Folder entries also get their own meta.json.
export const rootPages = [
  "index",
  "getting-started",
  "dictating",
  "cleanup-and-style",
  "dictionary",
  "transforms",
  "transcribe-audio-files",
  "automation",
  "editor-hints",
  "appearance",
  "privacy-and-data",
  "troubleshooting",
  "linux",
  "reference",
  "maintainers",
];

export const folders = {
  "getting-started": { title: "Getting started", pages: ["index", "install-notes"] },
  "cleanup-and-style": { title: "Cleanup and Style", pages: ["index", "writing-tools"] },
  automation: { title: "Automation", pages: ["index", "url-scheme-and-cli"] },
  "privacy-and-data": { title: "Privacy and data", pages: ["index", "saved-audio"] },
  linux: { title: "Linux", pages: ["index", "linux-desktop-setup", "linux-omarchy-plugin"] },
  reference: {
    title: "Reference",
    pages: [
      "settings",
      "spoken-commands",
      "known-limits",
      "security",
      "usage-overview",
      "release-readiness",
    ],
  },
  maintainers: { title: "Maintainers", pages: ["releasing", "mac-evaluations"] },
};

/** Page URL for a dest path ("a/index" -> "/a", "index" -> "/"). */
export function destToUrl(dest) {
  const trimmed = dest.replace(/(^|\/)index$/, "");
  return trimmed === "" ? "/" : `/${trimmed}`;
}
