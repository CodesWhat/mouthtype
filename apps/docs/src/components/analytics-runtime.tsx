"use client";

import { usePathname } from "next/navigation";
import { useReportWebVitals } from "next/web-vitals";
import posthog from "posthog-js/dist/module.slim";
import { useEffect, useRef } from "react";
import {
  createPostHogOptions,
  ctaIdForHref,
  isAllowedCta,
  isProductionHost,
  POSTHOG_PROJECT_KEY,
} from "@/lib/analytics-contract";
import { ANALYTICS_ROUTES } from "@/lib/analytics-routes.generated";
import { createVitalsBuffer, installVitalsFlush } from "@/lib/analytics-vitals";
import { BASE_PATH } from "@/lib/site-config";

let started = false;

// Only the production host is measured, and DNT and Global Privacy Control both switch
// measurement off there. Either way nothing is initialized.
function start(): boolean {
  if (started) return true;
  if (!isProductionHost(location.hostname)) return false;
  if (
    navigator.doNotTrack === "1" ||
    (navigator as { globalPrivacyControl?: boolean }).globalPrivacyControl === true
  ) {
    return false;
  }
  posthog.init(POSTHOG_PROJECT_KEY, createPostHogOptions(ANALYTICS_ROUTES, BASE_PATH));
  started = true;
  return true;
}

function captureCta(ctaId: string | null | undefined) {
  if (isAllowedCta(ctaId)) posthog.capture("cta activated", { cta_id: ctaId });
}

export function AnalyticsRuntime() {
  const pathname = usePathname();
  const vitals = useRef<ReturnType<typeof createVitalsBuffer> | null>(null);

  useEffect(() => {
    // Vitals are only sent while the page is going away. PostHog's own unload handler may already
    // have drained its queue by then, so they go out by beacon, and our listeners are registered
    // (capturing) before posthog.init so they run first.
    vitals.current = createVitalsBuffer((properties) =>
      posthog.capture("$web_vitals", properties, { transport: "sendBeacon", send_instantly: true }),
    );
    const buffer = vitals.current;
    const removeFlush = installVitalsFlush(window, buffer);
    if (!start()) {
      removeFlush();
      return;
    }
    // Delegated, so links inside the rendered Markdown are covered too. An explicit data-cta wins
    // over the href mapping.
    const onClick = (event: MouseEvent) => {
      const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
      if (!(link instanceof HTMLAnchorElement)) return;
      captureCta(
        link.dataset.cta ?? ctaIdForHref(link.getAttribute("href") ?? "", location.origin),
      );
    };
    document.addEventListener("click", onClick, true);
    return () => {
      document.removeEventListener("click", onClick, true);
      removeFlush();
    };
  }, []);

  // Pathname is the trigger only; the sanitizer reads the canonical path from the event itself.
  // biome-ignore lint/correctness/useExhaustiveDependencies: re-fire on every route change
  useEffect(() => {
    if (started) posthog.capture("$pageview");
  }, [pathname]);

  useReportWebVitals(({ name, value }) => vitals.current?.record(name, value));

  return null;
}
