import { WEB_VITAL_NAMES } from "./contract.js";

export const WEB_VITALS_FLUSH_DELAY_MS = 5000;

/**
 * Collects CLS, FCP, INP and LCP for one page load and emits a single properties object, once:
 * when all four have reported, when the flush delay after the first one runs out, or on flush().
 */
export function createVitalsBuffer(emit, schedule = setTimeout, cancel = clearTimeout) {
  const metrics = {};
  let timer;
  let sent = false;

  function flush() {
    if (sent) return;
    sent = true;
    if (timer !== undefined) cancel(timer);
    if (Object.keys(metrics).length > 0) emit({ ...metrics });
  }

  function record(name, value) {
    if (sent || !WEB_VITAL_NAMES.includes(name)) return;
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return;
    metrics[`$web_vitals_${name}_value`] = value;
    if (Object.keys(metrics).length === WEB_VITAL_NAMES.length) flush();
    else if (timer === undefined) timer = schedule(flush, WEB_VITALS_FLUSH_DELAY_MS);
  }

  return { record, flush };
}

/**
 * Flushes on visibilitychange→hidden and on pagehide, since some browsers fire only one of them
 * when a page is closed or navigated away. The buffer sends once, so firing both is safe.
 * Returns a cleanup function.
 */
export function installVitalsFlush(win, vitals) {
  const onHidden = () => {
    if (win.document.visibilityState === "hidden") vitals.flush();
  };
  const onPageHide = () => vitals.flush();
  win.document.addEventListener("visibilitychange", onHidden);
  win.addEventListener("pagehide", onPageHide);
  return () => {
    win.document.removeEventListener("visibilitychange", onHidden);
    win.removeEventListener("pagehide", onPageHide);
  };
}
