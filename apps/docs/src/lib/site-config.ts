export const SITE_CONFIG = {
  name: "Mouthtype",
  tagline: "Local dictation for Mac",
  description:
    "Documentation for Mouthtype, local dictation for Apple Silicon Macs running macOS 26 or later.",
  socialImage: "https://mouthtype.app/social/docs.png",
  github: "https://github.com/CodesWhat/mouthtype",
} as const;

// Where the site is served. Defaults to docs.mouthtype.app. Override with NEXT_PUBLIC_SITE_URL.
export const BASE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://docs.mouthtype.app";

/** "" at the root, "/docs" when built with DOCS_BASE_PATH=/docs. Prefix for URLs Next doesn't rewrite. */
export const BASE_PATH = process.env.NEXT_PUBLIC_DOCS_BASE_PATH ?? "";

/** Absolute canonical URL for a page path. The export uses trailing slashes. */
export function absoluteUrl(path: string) {
  return path === "/" ? BASE_URL : `${BASE_URL}${path.replace(/\/?$/, "/")}`;
}
