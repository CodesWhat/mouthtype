export const SITE_CONFIG = {
  name: "Mouthtype",
  tagline: "Local dictation for Mac",
  description:
    "Documentation for Mouthtype, local dictation for Apple Silicon Macs running macOS 26 or later.",
  github: "https://mouthtype.app",
} as const;

// Where the site is served. docs.mouthtype.app is the working assumption until the
// deploy target is decided. Override with NEXT_PUBLIC_SITE_URL.
export const BASE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://docs.mouthtype.app";
