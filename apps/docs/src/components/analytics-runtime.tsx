"use client";

import { usePathname } from "next/navigation";
import { useReportWebVitals } from "next/web-vitals";
import posthog from "posthog-js/dist/module.slim";
import { useEffect, useRef } from "react";
import {
  createPostHogOptions,
  ctaIdForHref,
  isAllowedCta,
  POSTHOG_PROJECT_KEY,
} from "@/lib/analytics-contract";
import { ANALYTICS_ROUTES } from "@/lib/analytics-routes.generated";
import { createVitalsBuffer, installVitalsFlush } from "@/lib/analytics-vitals";
import { BASE_PATH } from "@/lib/site-config";

let started = false;

// DNT and Global Privacy Control both switch measurement off before anything loads.
function start(): boolean {
  if (started) return true;
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
    if (!start()) return;
    vitals.current = createVitalsBuffer((properties) => posthog.capture("$web_vitals", properties));
    // Delegated, so links inside the rendered Markdown are covered too. An explicit data-cta wins
    // over the href mapping.
    const onClick = (event: MouseEvent) => {
      const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
      if (!(link instanceof HTMLAnchorElement)) return;
      captureCta(
        link.dataset.cta ?? ctaIdForHref(link.getAttribute("href") ?? "", location.origin),
      );
    };
    const buffer = vitals.current;
    document.addEventListener("click", onClick, true);
    const removeFlush = installVitalsFlush(window, buffer);
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
