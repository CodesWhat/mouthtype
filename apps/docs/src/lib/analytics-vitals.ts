import { WEB_VITAL_NAMES } from "./analytics-contract.ts";

/**
 * Collects CLS, FCP, INP and LCP for one page load, keeping the latest value per metric. CLS, INP
 * and LCP keep changing until the page is hidden, so nothing is sent until flush(), which the
 * lifecycle listeners call. A flush emits only the metrics that are new or changed since the last
 * one, so no value is sent twice and none is dropped.
 */
export function createVitalsBuffer(emit: (properties: Record<string, number>) => void) {
  const latest: Record<string, number> = {};
  const sent: Record<string, number> = {};
  const names: readonly string[] = WEB_VITAL_NAMES;

  function flush() {
    const changed: Record<string, number> = {};
    for (const [key, value] of Object.entries(latest)) {
      if (sent[key] !== value) changed[key] = value;
    }
    if (Object.keys(changed).length === 0) return;
    Object.assign(sent, changed);
    emit(changed);
  }

  function record(name: string, value: number) {
    if (!names.includes(name)) return;
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return;
    latest[`$web_vitals_${name}_value`] = value;
  }

  return { record, flush };
}

type FlushTarget = {
  document: Pick<Document, "addEventListener" | "removeEventListener" | "visibilityState">;
  addEventListener: (
    type: "pagehide",
    listener: () => void,
    options?: AddEventListenerOptions,
  ) => void;
  removeEventListener: (
    type: "pagehide",
    listener: () => void,
    options?: AddEventListenerOptions,
  ) => void;
};

/**
 * Flushes on visibilitychange→hidden and on pagehide, since some browsers fire only one of them
 * when a page is closed or navigated away. The buffer never repeats a value, so firing both is
 * safe. The listeners are capturing so they run before PostHog's own unload handler. Returns a
 * cleanup function.
 */
export function installVitalsFlush(win: FlushTarget, vitals: { flush: () => void }) {
  const onHidden = () => {
    if (win.document.visibilityState === "hidden") vitals.flush();
  };
  const onPageHide = () => vitals.flush();
  win.document.addEventListener("visibilitychange", onHidden, { capture: true });
  win.addEventListener("pagehide", onPageHide, { capture: true });
  return () => {
    win.document.removeEventListener("visibilitychange", onHidden, { capture: true });
    win.removeEventListener("pagehide", onPageHide, { capture: true });
  };
}
