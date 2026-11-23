// Event contract for docs.mouthtype.app. Every event is rebuilt from an allowlist, so nothing
// posthog-js collects reaches the wire unless a property is named here. Mirrors
// website/src/analytics/contract.js with surface "docs" and a generated route list.
// Standard: codeswhat-ops/standards/analytics.md (cookieless server hash, no person profiles).

const POSTHOG_API_HOST = "https://e.codeswhat.com";
const POSTHOG_UI_HOST = "https://us.posthog.com";
// Public, write-only ingestion key for the "CodesWhat Public Websites" project (558033).
export const POSTHOG_PROJECT_KEY = "phc_mav2oHZzTVaC4mAFEqaLbGEff65uvGMy47LcWSNBFp9J"; // gitleaks:allow (public write-only ingestion key)

const SCHEMA_VERSION = 1;
const SITE = "mouthtype";
const SURFACE = "docs";
const OTHER_PATH = "/_other";

const PROJECT_KEY_PATTERN = /^phc_[A-Za-z0-9_-]+$/u;
const COOKIELESS_DISTINCT_ID = "$posthog_cookieless";
const DIRECT_REFERRING_DOMAIN = "$direct";
const HOSTNAME_PATTERN =
  /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d{1,5})?$/iu;

// Measurement runs on the production site only. Local previews, CI runs and Vercel preview
// deployments serve the same build, and must not report into the production project.
const PRODUCTION_HOSTS: ReadonlySet<string> = new Set(["docs.mouthtype.app"]);

const CTA_IDS: ReadonlySet<string> = new Set(["download", "source_download", "github_repository"]);

export const WEB_VITAL_NAMES = ["CLS", "FCP", "INP", "LCP"] as const;

const EVENTS: ReadonlySet<string> = new Set([
  "$pageview",
  "$pageleave",
  "$web_vitals",
  "cta activated",
]);

type Properties = Record<string, unknown>;

export type CaptureEnvelope = {
  uuid: string;
  event: string;
  properties: Properties;
  timestamp?: Date;
  $set?: Properties;
  $set_once?: Properties;
};

/**
 * Drops query and fragment, the deployment base path and the trailing slash, then maps any route
 * that is not in the generated list to OTHER_PATH.
 */
export function canonicalizePath(
  rawPath: unknown,
  routes: ReadonlySet<string>,
  basePath = "",
): string {
  if (typeof rawPath !== "string" || !rawPath.startsWith("/") || rawPath.startsWith("//")) {
    return OTHER_PATH;
  }
  let path = rawPath.split(/[?#]/u, 1)[0];
  if (basePath !== "" && (path === basePath || path.startsWith(`${basePath}/`))) {
    path = path.slice(basePath.length) || "/";
  }
  const normalized = path === "/" ? path : path.replace(/\/+$/u, "");
  return routes.has(normalized) ? normalized : OTHER_PATH;
}

export function isAllowedCta(ctaId: unknown): ctaId is string {
  return typeof ctaId === "string" && CTA_IDS.has(ctaId);
}

/** Maps a link target to a stable cta_id, or null when the link is not a tracked CTA. */
export function ctaIdForHref(href: string, origin: string): string | null {
  let url: URL;
  try {
    url = new URL(href, origin);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  const path = url.pathname.replace(/\/+$/u, "");
  if (url.hostname === "mouthtype.app") {
    if (path === "/download" || path === "/download/file") return "download";
    if (path === "/source") return "source_download";
  }
  if (url.hostname === "github.com" && path === "/CodesWhat/mouthtype") return "github_repository";
  return null;
}

function pathFromProperties(properties: Properties): string | undefined {
  if (typeof properties.$current_url !== "string") return undefined;
  try {
    return new URL(properties.$current_url).pathname;
  } catch {
    return undefined;
  }
}

function isAcceptableReferringDomain(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length <= 253 &&
    (value === DIRECT_REFERRING_DOMAIN || HOSTNAME_PATTERN.test(value))
  );
}

/**
 * Builds the posthog-js `before_send`. The result is a new envelope assembled from named fields,
 * or null to drop the event. `$referrer` (the full URL), `$set`/`$set_once` and everything
 * unlisted never survive.
 */
export function createSanitizer(routes: ReadonlySet<string>, basePath = "") {
  return (envelope: CaptureEnvelope | null): CaptureEnvelope | null => {
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

    const path = canonicalizePath(rawPath, routes, basePath);
    const properties: Properties = {
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
    if (input.distinct_id === COOKIELESS_DISTINCT_ID) {
      properties.distinct_id = COOKIELESS_DISTINCT_ID;
    }

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

    const output: CaptureEnvelope = { uuid: envelope.uuid, event: envelope.event, properties };
    if (envelope.timestamp instanceof Date && Number.isFinite(envelope.timestamp.getTime())) {
      output.timestamp = envelope.timestamp;
    }
    return output;
  };
}

/** True only for an exact production hostname (`location.hostname`, so no port). */
export function isProductionHost(hostname: unknown): boolean {
  return typeof hostname === "string" && PRODUCTION_HOSTS.has(hostname);
}

/**
 * DNT and Global Privacy Control both switch measurement off. posthog-js 1.449.2 ignores
 * `respect_dnt` under cookieless_mode "always", so this is also checked in `before_send`.
 */
export function isOptedOut(
  nav: { doNotTrack?: string | null; globalPrivacyControl?: boolean } | undefined | null,
): boolean {
  return !!nav && (nav.doNotTrack === "1" || nav.globalPrivacyControl === true);
}

export function createPostHogOptions(
  routes: ReadonlySet<string>,
  basePath = "",
  nav: Parameters<typeof isOptedOut>[0] = globalThis.navigator,
) {
  const sanitize = createSanitizer(routes, basePath);
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
    before_send: (envelope: CaptureEnvelope | null) =>
      isOptedOut(nav) ? null : sanitize(envelope),
  } as const;
}
