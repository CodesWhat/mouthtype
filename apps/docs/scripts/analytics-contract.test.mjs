import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  canonicalizePath,
  createPostHogOptions,
  createSanitizer,
  ctaIdForHref,
  isAllowedCta,
  isProductionHost,
  POSTHOG_PROJECT_KEY,
} from "../src/lib/analytics-contract.ts";
import { ANALYTICS_ROUTES } from "../src/lib/analytics-routes.generated.ts";
import { createVitalsBuffer, installVitalsFlush } from "../src/lib/analytics-vitals.ts";
import {
  collectAnalyticsRoutes,
  renderAnalyticsRoutes,
  routesAreCurrent,
} from "./analytics-routes.mjs";

const ROUTES = new Set(["/", "/dictating", "/getting-started"]);
const sanitize = createSanitizer(ROUTES);

function envelope(event, extra = {}, top = {}) {
  return {
    uuid: "0194c000-0000-7000-8000-000000000000",
    event,
    properties: {
      token: POSTHOG_PROJECT_KEY,
      distinct_id: "$posthog_cookieless",
      $cookieless_mode: true,
      $process_person_profile: false,
      $raw_user_agent: "Mozilla/5.0 Test",
      $host: "docs.mouthtype.app",
      $current_url: "https://docs.mouthtype.app/dictating/?q=secret&email=a@b.example#frag",
      $referrer: "https://news.example/private/thread?id=7",
      $referring_domain: "news.example",
      $initial_referrer: "https://news.example/private/thread?id=7",
      $session_id: "session",
      utm_source: "x",
      email: "a@b.example",
      ...extra,
    },
    ...top,
  };
}

test("every event carries schema_version, site, surface docs and a canonical path", () => {
  const out = sanitize(envelope("$pageview"));
  assert.equal(out.properties.schema_version, 1);
  assert.equal(out.properties.site, "mouthtype");
  assert.equal(out.properties.surface, "docs");
  assert.equal(out.properties.path, "/dictating");
  assert.equal(out.properties.$pathname, "/dictating");
});

test("the allowlist drops unknown properties and person-property envelopes", () => {
  const out = sanitize(
    envelope("$pageview", {}, { $set: { email: "a@b.example" }, $set_once: { x: 1 } }),
  );
  assert.deepEqual(Object.keys(out).sort(), ["event", "properties", "uuid"]);
  for (const dropped of [
    "$referrer",
    "$initial_referrer",
    "$current_url",
    "$session_id",
    "utm_source",
    "email",
  ]) {
    assert.equal(dropped in out.properties, false, dropped);
  }
  assert.doesNotMatch(JSON.stringify(out), /a@b\.example|private\/thread|utm_source|secret/);
});

test("$referring_domain is kept when it is a bare hostname and $referrer is never copied", () => {
  const out = sanitize(envelope("$pageview"));
  assert.equal(out.properties.$referring_domain, "news.example");
  assert.equal("$referrer" in out.properties, false);
  assert.equal(
    sanitize(envelope("$pageview", { $referring_domain: "$direct" })).properties.$referring_domain,
    "$direct",
  );
  for (const bad of ["https://news.example/x", "news.example/path", "a b", "", 5]) {
    const result = sanitize(envelope("$pageview", { $referring_domain: bad }));
    assert.equal("$referring_domain" in result.properties, false, String(bad));
  }
});

test("paths are canonicalised: no query, no fragment, no trailing slash, base path removed", () => {
  assert.equal(canonicalizePath("/dictating/?a=1#b", ROUTES), "/dictating");
  assert.equal(canonicalizePath("/", ROUTES), "/");
  assert.equal(canonicalizePath("/?x=1", ROUTES), "/");
  assert.equal(canonicalizePath("/nope/42", ROUTES), "/_other");
  assert.equal(canonicalizePath("//evil.example", ROUTES), "/_other");
  assert.equal(canonicalizePath("dictating", ROUTES), "/_other");
  assert.equal(canonicalizePath(undefined, ROUTES), "/_other");
  assert.equal(canonicalizePath("/docs/dictating/", ROUTES, "/docs"), "/dictating");
  assert.equal(canonicalizePath("/docs", ROUTES, "/docs"), "/");
  assert.equal(canonicalizePath("/docsx", ROUTES, "/docs"), "/_other");
  const odd = sanitize(
    envelope("$pageview", { $current_url: "https://docs.mouthtype.app/x/1?q=2" }),
  );
  assert.equal(odd.properties.path, "/_other");
});

test("cta_id is validated against the allowlist", () => {
  assert.equal(
    sanitize(envelope("cta activated", { cta_id: "download" })).properties.cta_id,
    "download",
  );
  assert.equal(sanitize(envelope("cta activated", { cta_id: "free text" })), null);
  assert.equal(sanitize(envelope("cta activated", {})), null);
  assert.equal(sanitize(envelope("cta activated", { cta_id: ["download"] })), null);
  assert.equal(isAllowedCta("github_repository"), true);
  assert.equal(isAllowedCta("install_brew"), false);
});

test("web vitals keep only the four finite non-negative values", () => {
  const out = sanitize(
    envelope("$web_vitals", {
      $web_vitals_LCP_value: 1200,
      $web_vitals_CLS_value: 0.01,
      $web_vitals_INP_value: -1,
      $web_vitals_FCP_value: Number.NaN,
      $web_vitals_TTFB_value: 50,
      $web_vitals_LCP_event: { target: "div#secret" },
    }),
  );
  assert.equal(out.properties.$web_vitals_LCP_value, 1200);
  assert.equal(out.properties.$web_vitals_CLS_value, 0.01);
  for (const key of [
    "$web_vitals_INP_value",
    "$web_vitals_FCP_value",
    "$web_vitals_TTFB_value",
    "$web_vitals_LCP_event",
  ]) {
    assert.equal(key in out.properties, false, key);
  }
  assert.equal(sanitize(envelope("$web_vitals", {})), null);
});

test("events outside the vocabulary and malformed envelopes are dropped", () => {
  assert.equal(sanitize(envelope("$autocapture")), null);
  assert.equal(sanitize(null), null);
  assert.equal(sanitize({ event: "$pageview" }), null);
  assert.equal(sanitize(envelope("$pageview", { token: "nope" })), null);
  assert.equal(sanitize(envelope("$pageview", { $cookieless_mode: false })), null);
  assert.equal(sanitize(envelope("$pageview", { $process_person_profile: true })), null);
  assert.equal(sanitize(envelope("$pageview", { $raw_user_agent: "" })), null);
  assert.equal(sanitize(envelope("$pageview", { $host: undefined })), null);
  assert.equal(sanitize(envelope("$pageview", { $current_url: "not a url" })), null);
});

test("timestamps and $pageleave", () => {
  const when = new Date("2026-01-01T00:00:00Z");
  assert.equal(sanitize(envelope("$pageview", {}, { timestamp: when })).timestamp, when);
  assert.equal(
    "timestamp" in sanitize(envelope("$pageview", {}, { timestamp: new Date("x") })),
    false,
  );
  const leave = sanitize(envelope("$pageleave", { $prev_pageview_duration: 12 }));
  assert.equal(leave.event, "$pageleave");
  assert.equal("$prev_pageview_duration" in leave.properties, false);
});

test("href mapping yields stable cta ids", () => {
  const origin = "https://docs.mouthtype.app";
  assert.equal(ctaIdForHref("https://mouthtype.app/download", origin), "download");
  assert.equal(ctaIdForHref("https://mouthtype.app/download/", origin), "download");
  assert.equal(ctaIdForHref("https://mouthtype.app/source", origin), "source_download");
  assert.equal(ctaIdForHref("https://github.com/CodesWhat/mouthtype", origin), "github_repository");
  assert.equal(ctaIdForHref("https://github.com/CodesWhat/mouthtype/issues", origin), null);
  assert.equal(ctaIdForHref("/dictating/", origin), null);
  assert.equal(ctaIdForHref("http://mouthtype.app/download", origin), null);
  assert.equal(ctaIdForHref("http://[bad", origin), null);
});

test("posthog options keep the privacy posture", () => {
  const options = createPostHogOptions(ROUTES);
  assert.equal(options.api_host, "https://e.codeswhat.com");
  assert.equal(options.cookieless_mode, "always");
  assert.equal(options.person_profiles, "never");
  assert.equal(options.persistence, "memory");
  assert.equal(options.respect_dnt, true);
  assert.equal(options.save_campaign_params, false);
  assert.equal(options.autocapture, false);
  assert.equal(typeof options.before_send, "function");
});

test("the vitals buffer keeps the latest value per metric and sends only on flush", () => {
  const sent = [];
  const buffer = createVitalsBuffer((properties) => sent.push(properties));
  buffer.record("LCP", 1000);
  buffer.record("NOPE", 1);
  buffer.record("CLS", -1);
  buffer.record("FCP", Number.NaN);
  buffer.record("CLS", 0.1);
  assert.deepEqual(sent, [], "nothing is sent before a flush, even with all four in");
  for (const name of ["FCP", "INP"]) buffer.record(name, 1);
  buffer.record("LCP", 1200);
  buffer.flush();
  assert.deepEqual(sent, [
    {
      $web_vitals_LCP_value: 1200,
      $web_vitals_CLS_value: 0.1,
      $web_vitals_FCP_value: 1,
      $web_vitals_INP_value: 1,
    },
  ]);
  buffer.flush();
  assert.equal(sent.length, 1, "an unchanged buffer sends nothing");
  const empty = [];
  createVitalsBuffer((properties) => empty.push(properties)).flush();
  assert.deepEqual(empty, []);
});

test("metrics arriving after the old 5s window are kept and sent once, never twice", () => {
  const sent = [];
  const buffer = createVitalsBuffer((properties) => sent.push(properties));
  buffer.record("FCP", 300);
  buffer.flush();
  // CLS, INP and LCP report late, on interaction or page hide.
  buffer.record("CLS", 0.05);
  buffer.record("CLS", 0.2);
  buffer.record("INP", 90);
  buffer.record("LCP", 2500);
  buffer.flush();
  buffer.flush();
  assert.deepEqual(sent, [
    { $web_vitals_FCP_value: 300 },
    { $web_vitals_CLS_value: 0.2, $web_vitals_INP_value: 90, $web_vitals_LCP_value: 2500 },
  ]);
});

test("the generated route list matches the docs manifest", () => {
  const target = fileURLToPath(
    new URL("../src/lib/analytics-routes.generated.ts", import.meta.url),
  );
  const routes = collectAnalyticsRoutes();
  assert.ok(routes.includes("/") && routes.includes("/getting-started"));
  assert.ok(routes.every((route) => route === "/" || !route.endsWith("/")));
  assert.equal(routesAreCurrent(target, renderAnalyticsRoutes(routes)), true);
  assert.equal(routesAreCurrent(`${target}.missing`, ""), false);
  assert.equal(fs.readFileSync(target, "utf8").includes('"/"'), true);
  assert.deepEqual([...ANALYTICS_ROUTES].sort(), routes);
});

test("before_send drops every event under DNT or GPC, and passes otherwise", () => {
  const clean = envelope("$pageview");
  for (const nav of [{ doNotTrack: "1" }, { globalPrivacyControl: true }]) {
    assert.equal(createPostHogOptions(ROUTES, "", nav).before_send(clean), null);
  }
  const allowed = createPostHogOptions(ROUTES, "", {
    doNotTrack: "0",
    globalPrivacyControl: false,
  }).before_send(clean);
  assert.equal(allowed.event, "$pageview");
  assert.equal(createPostHogOptions(ROUTES, "", undefined).before_send(clean).event, "$pageview");
});

test("only the production docs host counts as production", () => {
  assert.equal(isProductionHost("docs.mouthtype.app"), true);
  for (const host of [
    "127.0.0.1",
    "localhost",
    "mouthtype-docs-git-dev-codeswhat.vercel.app",
    "mouthtype.app",
    "docs.mouthtype.app.evil.com",
    "xdocs.mouthtype.app",
    "preview.docs.mouthtype.app",
    "docs.mouthtype.app:4178",
    "DOCS.MOUTHTYPE.APP.",
    "",
    undefined,
    null,
  ]) {
    assert.equal(isProductionHost(host), false, String(host));
  }
});

test("installVitalsFlush sends buffered CLS and INP once across visibilitychange and pagehide", () => {
  const sent = [];
  const buffer = createVitalsBuffer((properties) => sent.push(properties));
  buffer.record("CLS", 0.2);
  buffer.record("INP", 80);
  const doc = new EventTarget();
  doc.visibilityState = "visible";
  const win = new EventTarget();
  win.document = doc;
  const remove = installVitalsFlush(win, buffer);

  doc.dispatchEvent(new Event("visibilitychange"));
  assert.equal(sent.length, 0, "visible does not flush");
  win.dispatchEvent(new Event("pagehide"));
  assert.deepEqual(sent, [{ $web_vitals_CLS_value: 0.2, $web_vitals_INP_value: 80 }]);
  doc.visibilityState = "hidden";
  doc.dispatchEvent(new Event("visibilitychange"));
  win.dispatchEvent(new Event("pagehide"));
  assert.equal(sent.length, 1, "second flush sends nothing");

  remove();
  const later = [];
  const buffer2 = createVitalsBuffer((p) => later.push(p));
  buffer2.record("CLS", 0.1);
  const remove2 = installVitalsFlush(win, buffer2);
  remove2();
  win.dispatchEvent(new Event("pagehide"));
  assert.equal(later.length, 0, "cleanup removes the listeners");
});
