import posthog from "posthog-js/dist/module.slim";
import { onCLS, onFCP, onINP, onLCP } from "web-vitals";
import {
  createPostHogOptions,
  ctaIdForHref,
  isAllowedCta,
  isOptedOut,
  isProductionHost,
  POSTHOG_PROJECT_KEY,
} from "./contract.js";
import { createVitalsBuffer, installVitalsFlush } from "./vitals.js";

export { isOptedOut };

function captureCta(ctaId) {
  if (isAllowedCta(ctaId)) posthog.capture("cta activated", { cta_id: ctaId });
}

// Delegated, so every page is covered without per-link wiring. An explicit data-cta wins over
// the href mapping.
function installCtaTracking(doc, origin) {
  doc.addEventListener(
    "click",
    (event) => {
      const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
      if (!link) return;
      captureCta(link.dataset.cta ?? ctaIdForHref(link.getAttribute("href"), origin));
    },
    true,
  );
  // The brew command is selectable text, not a link: copying it counts as the install CTA.
  doc.addEventListener("copy", () => {
    const anchor = doc.getSelection()?.anchorNode;
    const element = anchor instanceof Element ? anchor : anchor?.parentElement;
    const tagged = element?.closest("[data-cta]");
    if (tagged && !tagged.closest("a")) captureCta(tagged.dataset.cta);
  });
}

export function startAnalytics(win = window) {
  // Only the production host is measured; anywhere else nothing is initialized or listened for.
  if (!isProductionHost(win.location?.hostname)) return false;
  if (isOptedOut(win.navigator)) return false;
  // Vitals are only sent while the page is going away. PostHog's own unload handler may already
  // have drained its queue by then, so they go out by beacon, and our listeners are registered
  // (capturing) before init so they run first.
  const vitals = createVitalsBuffer((properties) =>
    posthog.capture("$web_vitals", properties, { transport: "sendBeacon", send_instantly: true }),
  );
  installVitalsFlush(win, vitals);
  posthog.init(POSTHOG_PROJECT_KEY, createPostHogOptions(win.navigator));
  posthog.capture("$pageview");

  const report = ({ name, value }) => vitals.record(name, value);
  onCLS(report);
  onFCP(report);
  onINP(report);
  onLCP(report);

  installCtaTracking(win.document, win.location.origin);
  return true;
}
