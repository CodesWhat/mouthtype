import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";

import {
  canonicalizePath,
  createPostHogOptions,
  ctaIdForHref,
  isAllowedCta,
  isProductionHost,
  POSTHOG_PROJECT_KEY,
  sanitizeEvent,
} from "../src/analytics/contract.js";
import { createVitalsBuffer, installVitalsFlush } from "../src/analytics/vitals.js";

// client.js imports posthog-js by a path only the bundler resolves. Node gets a recorder instead,
// which also shows whether init or capture was ever called.
const POSTHOG_STUB =
  "data:text/javascript,export default {calls:[],init(){this.calls.push('init')},capture(){this.calls.push('capture')}}";
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "posthog-js/dist/module.slim") {
      return { url: POSTHOG_STUB, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
});
const { default: posthog } = await import(POSTHOG_STUB);
const { startAnalytics } = await import("../src/analytics/client.js");

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
      $host: "mouthtype.app",
      $current_url: "https://mouthtype.app/start/?utm_source=x&email=a@b.example#frag",
      $referrer: "https://news.example/private/thread?id=7",
      $referring_domain: "news.example",
      $initial_referrer: "https://news.example/private/thread?id=7",
      $device_id: "device",
      $session_id: "session",
      utm_source: "x",
      email: "a@b.example",
      ...extra,
    },
    ...top,
  };
}

test("every event carries schema_version, site, surface and a canonical path", () => {
  const out = sanitizeEvent(envelope("$pageview"));
  assert.equal(out.properties.schema_version, 1);
  assert.equal(out.properties.site, "mouthtype");
  assert.equal(out.properties.surface, "marketing");
  assert.equal(out.properties.path, "/start");
  assert.equal(out.properties.$pathname, "/start");
});

test("the allowlist drops unknown properties and person-property envelopes", () => {
  const out = sanitizeEvent(
    envelope(
      "$pageview",
      {},
      { $set: { email: "a@b.example" }, $set_once: { $initial_referrer: "x" } },
    ),
  );
  assert.deepEqual(Object.keys(out).sort(), ["event", "properties", "uuid"]);
  for (const dropped of [
    "$referrer",
    "$initial_referrer",
    "$current_url",
    "$device_id",
    "$session_id",
    "utm_source",
    "email",
  ]) {
    assert.equal(dropped in out.properties, false, dropped);
  }
  assert.doesNotMatch(JSON.stringify(out), /a@b\.example|private\/thread|utm_source/);
});

test("$referring_domain is kept when it is a bare hostname and $referrer is never copied", () => {
  const out = sanitizeEvent(envelope("$pageview"));
  assert.equal(out.properties.$referring_domain, "news.example");
  assert.equal("$referrer" in out.properties, false);
  assert.equal(
    sanitizeEvent(envelope("$pageview", { $referring_domain: "$direct" })).properties
      .$referring_domain,
    "$direct",
  );
  for (const bad of [
    "https://news.example/x",
    "news.example/path",
    "a b",
    "",
    5,
    "x".repeat(300),
  ]) {
    const result = sanitizeEvent(envelope("$pageview", { $referring_domain: bad }));
    assert.equal("$referring_domain" in result.properties, false, String(bad));
  }
});

test("paths are canonicalised: no query, no fragment, no trailing slash, unknown routes bucketed", () => {
  assert.equal(canonicalizePath("/start/?a=1#b"), "/start");
  assert.equal(canonicalizePath("/compare/wispr-flow/"), "/compare/wispr-flow");
  assert.equal(canonicalizePath("/"), "/");
  assert.equal(canonicalizePath("/?x=1"), "/");
  assert.equal(canonicalizePath("/account/reset/abc123"), "/_other");
  assert.equal(canonicalizePath("//evil.example/start"), "/_other");
  assert.equal(canonicalizePath("start"), "/_other");
  assert.equal(canonicalizePath(undefined), "/_other");
  const odd = sanitizeEvent(
    envelope("$pageview", { $current_url: "https://mouthtype.app/secret/42?q=1#x" }),
  );
  assert.equal(odd.properties.path, "/_other");
});

test("cta_id is validated against the allowlist", () => {
  const ok = sanitizeEvent(envelope("cta activated", { cta_id: "download" }));
  assert.equal(ok.properties.cta_id, "download");
  assert.equal(sanitizeEvent(envelope("cta activated", { cta_id: "free text" })), null);
  assert.equal(sanitizeEvent(envelope("cta activated", {})), null);
  assert.equal(sanitizeEvent(envelope("cta activated", { cta_id: { id: "download" } })), null);
  assert.equal(isAllowedCta("install_brew"), true);
  assert.equal(isAllowedCta("nope"), false);
});

test("web vitals keep only the four finite non-negative values", () => {
  const out = sanitizeEvent(
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
  assert.equal(sanitizeEvent(envelope("$web_vitals", {})), null);
});

test("events outside the vocabulary and malformed envelopes are dropped", () => {
  assert.equal(sanitizeEvent(envelope("$autocapture")), null);
  assert.equal(sanitizeEvent(envelope("$identify")), null);
  assert.equal(sanitizeEvent(null), null);
  assert.equal(sanitizeEvent({ event: "$pageview" }), null);
  assert.equal(sanitizeEvent(envelope("$pageview", { token: "nope" })), null);
  assert.equal(sanitizeEvent(envelope("$pageview", { $cookieless_mode: false })), null);
  assert.equal(sanitizeEvent(envelope("$pageview", { $process_person_profile: true })), null);
  assert.equal(sanitizeEvent(envelope("$pageview", { $raw_user_agent: "" })), null);
  assert.equal(sanitizeEvent(envelope("$pageview", { $host: undefined })), null);
  assert.equal(sanitizeEvent(envelope("$pageview", { $current_url: "not a url" })), null);
});

test("a valid timestamp is kept and an invalid one is not", () => {
  const when = new Date("2026-01-01T00:00:00Z");
  assert.equal(sanitizeEvent(envelope("$pageview", {}, { timestamp: when })).timestamp, when);
  const bad = sanitizeEvent(envelope("$pageview", {}, { timestamp: new Date("x") }));
  assert.equal("timestamp" in bad, false);
});

test("$pageleave goes through the same rebuild", () => {
  const out = sanitizeEvent(envelope("$pageleave", { $prev_pageview_duration: 12 }));
  assert.equal(out.event, "$pageleave");
  assert.equal("$prev_pageview_duration" in out.properties, false);
});

test("href mapping yields stable cta ids", () => {
  const origin = "https://mouthtype.app";
  assert.equal(ctaIdForHref("/download/", origin), "download");
  assert.equal(ctaIdForHref("/download/file", origin), "download");
  assert.equal(ctaIdForHref("/source", origin), "source_download");
  assert.equal(ctaIdForHref("/start/", origin), null);
  assert.equal(ctaIdForHref("https://docs.mouthtype.app/", origin), "docs_root");
  assert.equal(ctaIdForHref("https://docs.mouthtype.app/dictating/#x", origin), "docs_page");
  assert.equal(ctaIdForHref("https://github.com/CodesWhat/mouthtype", origin), "github_repository");
  assert.equal(ctaIdForHref("https://github.com/sponsors/CodesWhat", origin), "github_sponsors");
  assert.equal(ctaIdForHref("https://codeswhat.com/support", origin), "support_donate");
  assert.equal(ctaIdForHref("https://codeswhat.com", origin), null);
  assert.equal(ctaIdForHref("http://docs.mouthtype.app/", origin), null);
  assert.equal(ctaIdForHref("http://[bad", origin), null);
});

test("posthog options keep the privacy posture", () => {
  const options = createPostHogOptions();
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

test("before_send drops every event under DNT or GPC, and passes otherwise", () => {
  const clean = envelope("$pageview");
  for (const nav of [{ doNotTrack: "1" }, { globalPrivacyControl: true }]) {
    assert.equal(createPostHogOptions(nav).before_send(clean), null);
  }
  const allowed = createPostHogOptions({ doNotTrack: "0", globalPrivacyControl: false }).before_send(clean);
  assert.equal(allowed.event, "$pageview");
  assert.equal(createPostHogOptions(undefined).before_send(clean).event, "$pageview");
});

test("only the production site host counts as production", () => {
  assert.equal(isProductionHost("mouthtype.app"), true);
  for (const host of [
    "127.0.0.1",
    "localhost",
    "mouthtype-git-dev-codeswhat.vercel.app",
    "www.mouthtype.app",
    "docs.mouthtype.app",
    "mouthtype.app.evil.com",
    "xmouthtype.app",
    "mouthtype.app:4177",
    "MOUTHTYPE.APP.",
    "",
    undefined,
    null,
  ]) {
    assert.equal(isProductionHost(host), false, String(host));
  }
});

test("startAnalytics does nothing off the production host", () => {
  // Any listener, document or navigator access would mean setup had begun.
  const untouched = (name) => ({
    get() {
      throw new Error(`${name} was read on a non-production host`);
    },
  });
  for (const hostname of ["127.0.0.1", "localhost", "mouthtype-git-dev-codeswhat.vercel.app", ""]) {
    const win = Object.defineProperties(
      { location: { hostname, origin: `http://${hostname}` } },
      {
        navigator: untouched("navigator"),
        document: untouched("document"),
        addEventListener: untouched("addEventListener"),
      },
    );
    assert.equal(startAnalytics(win), false, hostname);
  }
  assert.equal(startAnalytics({ navigator: {} }), false, "no location at all");
  assert.deepEqual(posthog.calls, [], "posthog.init and capture were never called");
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
