// Event contract for the Mouthtype marketing site. Every event is rebuilt here from an
// allowlist, so nothing posthog-js collects reaches the wire unless a property is named below.
// Standard: codeswhat-ops/standards/analytics.md (cookieless server hash, no person profiles).

export const POSTHOG_API_HOST = "https://e.codeswhat.com";
export const POSTHOG_UI_HOST = "https://us.posthog.com";
// Public, write-only ingestion key for the "CodesWhat Public Websites" project (558033).
export const POSTHOG_PROJECT_KEY = "phc_mav2oHZzTVaC4mAFEqaLbGEff65uvGMy47LcWSNBFp9J"; // gitleaks:allow (public write-only ingestion key)

export const SCHEMA_VERSION = 1;
export const SITE = "mouthtype";
export const SURFACE = "marketing";
export const OTHER_PATH = "/_other";

const PROJECT_KEY_PATTERN = /^phc_[A-Za-z0-9_-]+$/u;
const COOKIELESS_DISTINCT_ID = "$posthog_cookieless";
const DIRECT_REFERRING_DOMAIN = "$direct";
const HOSTNAME_PATTERN =
  /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d{1,5})?$/iu;

// Measurement runs on the production site only. Local previews, CI runs and Vercel preview
// deployments serve the same build, and must not report into the production project.
export const PRODUCTION_HOSTS = new Set(["mouthtype.app"]);

// One entry per page in vite.config.js. Anything else is reported as OTHER_PATH.
export const ROUTES = new Set([
  "/",
  "/start",
  "/download",
  "/linux",
  "/why-mouthtype",
  "/compare",
  "/compare/apple-dictation",
  "/compare/wispr-flow",
]);

export const CTA_IDS = new Set([
  "download",
  "install_brew",
  "source_download",
  "docs_root",
  "docs_page",
  "github_repository",
  "github_sponsors",
  "support_donate",
]);

export const WEB_VITAL_NAMES = ["CLS", "FCP", "INP", "LCP"];

const EVENTS = new Set(["$pageview", "$pageleave", "$web_vitals", "cta activated"]);

/** Drops query and fragment, strips the trailing slash, and maps unknown routes to OTHER_PATH. */
export function canonicalizePath(rawPath) {
  if (typeof rawPath !== "string" || !rawPath.startsWith("/") || rawPath.startsWith("//")) {
    return OTHER_PATH;
  }
  const bare = rawPath.split(/[?#]/u, 1)[0];
  const normalized = bare === "/" ? bare : bare.replace(/\/+$/u, "");
  return ROUTES.has(normalized) ? normalized : OTHER_PATH;
}

export function isAllowedCta(ctaId) {
  return typeof ctaId === "string" && CTA_IDS.has(ctaId);
}

/** Maps a link target to a stable cta_id, or null when the link is not a tracked CTA. */
export function ctaIdForHref(href, origin) {
  let url;
  try {
    url = new URL(href, origin);
  } catch {
    return null;
  }
  const path = url.pathname.replace(/\/+$/u, "");
  if (url.origin === origin) {
    if (path === "/download" || path === "/download/file") return "download";
    if (path === "/source") return "source_download";
    return null;
  }
  if (url.protocol !== "https:") return null;
  if (url.hostname === "docs.mouthtype.app") return path === "" ? "docs_root" : "docs_page";
  if (url.hostname === "github.com") {
    if (path === "/CodesWhat/mouthtype") return "github_repository";
    if (path === "/sponsors/CodesWhat") return "github_sponsors";
  }
  if (url.hostname === "codeswhat.com" && path === "/support") return "support_donate";
  return null;
}

function pathFromProperties(properties) {
  if (typeof properties.$current_url !== "string") return undefined;
  try {
    return new URL(properties.$current_url).pathname;
  } catch {
    return undefined;
  }
}

function isAcceptableReferringDomain(value) {
  return (
    typeof value === "string" &&
    value.length <= 253 &&
    (value === DIRECT_REFERRING_DOMAIN || HOSTNAME_PATTERN.test(value))
  );
}

/**
 * posthog-js `before_send`. Returns a new envelope built from named fields, or null to drop the
 * event. `$referrer` (the full URL), `$set`/`$set_once` and everything unlisted never survive.
 */
export function sanitizeEvent(envelope) {
  if (!envelope || typeof envelope.event !== "string" || !EVENTS.has(envelope.event)) return null;
  const input = envelope.properties;
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;

  const key = input.token;
  const rawPath = pathFromProperties(input);
  // Cookieless server hashing reads $raw_user_agent and $host off the properties and drops the
  // event if either is missing. $ip is never sent; the capture service fills it in itself.
  if (
    typeof key !== "string" ||
    !PROJECT_KEY_PATTERN.test(key) ||
    typeof rawPath !== "string" ||
    input.$cookieless_mode !== true ||
    input.$process_person_profile !== false ||
    typeof input.$raw_user_agent !== "string" ||
    input.$raw_user_agent === "" ||
    typeof input.$host !== "string" ||
    input.$host === ""
  ) {
    return null;
  }

  const path = canonicalizePath(rawPath);
  const properties = {
    token: key,
    $cookieless_mode: true,
    $process_person_profile: false,
    $raw_user_agent: input.$raw_user_agent,
    $host: input.$host,
    schema_version: SCHEMA_VERSION,
    site: SITE,
    surface: SURFACE,
    path,
  };
  if (input.distinct_id === COOKIELESS_DISTINCT_ID) properties.distinct_id = COOKIELESS_DISTINCT_ID;

  if (envelope.event === "$pageview" || envelope.event === "$pageleave") {
    properties.$pathname = path;
    if (isAcceptableReferringDomain(input.$referring_domain)) {
      properties.$referring_domain = input.$referring_domain;
    }
  } else if (envelope.event === "cta activated") {
    if (!isAllowedCta(input.cta_id)) return null;
    properties.cta_id = input.cta_id;
  } else {
    let metrics = 0;
    for (const name of WEB_VITAL_NAMES) {
      const value = input[`$web_vitals_${name}_value`];
      if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
        properties[`$web_vitals_${name}_value`] = value;
        metrics += 1;
      }
    }
    if (metrics === 0) return null;
  }

  const output = { uuid: envelope.uuid, event: envelope.event, properties };
  if (envelope.timestamp instanceof Date && Number.isFinite(envelope.timestamp.getTime())) {
    output.timestamp = envelope.timestamp;
  }
  return output;
}

/** True only for an exact production hostname (`location.hostname`, so no port). */
export function isProductionHost(hostname) {
  return typeof hostname === "string" && PRODUCTION_HOSTS.has(hostname);
}

/**
 * DNT and Global Privacy Control both switch measurement off. posthog-js 1.449.2 ignores
 * `respect_dnt` under cookieless_mode "always", so this is also checked in `before_send`.
 */
export function isOptedOut(nav) {
  return !!nav && (nav.doNotTrack === "1" || nav.globalPrivacyControl === true);
}

export function createPostHogOptions(nav = globalThis.navigator) {
  return {
    api_host: POSTHOG_API_HOST,
    ui_host: POSTHOG_UI_HOST,
    autocapture: false,
    rageclick: false,
    capture_pageview: false,
    capture_pageleave: true,
    capture_heatmaps: false,
    capture_dead_clicks: false,
    capture_exceptions: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_surveys_automatic_display: true,
    disable_product_tours: true,
    disable_web_experiments: true,
    advanced_disable_flags: true,
    cookieless_mode: "always",
    person_profiles: "never",
    persistence: "memory",
    disable_persistence: true,
    respect_dnt: true,
    save_campaign_params: false,
    save_referrer: true,
    disable_capture_url_hashes: true,
    disable_scroll_properties: true,
    mask_all_element_attributes: true,
    mask_all_text: true,
    capture_performance: false,
    before_send: (envelope) => (isOptedOut(nav) ? null : sanitizeEvent(envelope)),
  };
}
