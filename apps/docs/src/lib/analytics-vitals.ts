import { WEB_VITAL_NAMES } from "./analytics-contract.ts";

const WEB_VITALS_FLUSH_DELAY_MS = 5000;

type Timer = unknown;

/**
 * Collects CLS, FCP, INP and LCP for one page load and emits a single properties object, once:
 * when all four have reported, when the flush delay after the first one runs out, or on flush().
 */
export function createVitalsBuffer(
  emit: (properties: Record<string, number>) => void,
  schedule: (callback: () => void, delayMs: number) => Timer = setTimeout,
  cancel: (timer: Timer) => void = (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
) {
  const metrics: Record<string, number> = {};
  const names: readonly string[] = WEB_VITAL_NAMES;
  let timer: Timer;
  let sent = false;

  function flush() {
    if (sent) return;
    sent = true;
    if (timer !== undefined) cancel(timer);
    if (Object.keys(metrics).length > 0) emit({ ...metrics });
  }

  function record(name: string, value: number) {
    if (sent || !names.includes(name)) return;
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return;
    metrics[`$web_vitals_${name}_value`] = value;
    if (Object.keys(metrics).length === names.length) flush();
    else if (timer === undefined) timer = schedule(flush, WEB_VITALS_FLUSH_DELAY_MS);
  }

  return { record, flush };
}

type FlushTarget = {
  document: Pick<Document, "addEventListener" | "removeEventListener" | "visibilityState">;
  addEventListener: (type: "pagehide", listener: () => void) => void;
  removeEventListener: (type: "pagehide", listener: () => void) => void;
};

/**
 * Flushes on visibilitychange→hidden and on pagehide, since some browsers fire only one of them
 * when a page is closed or navigated away. The buffer sends once, so firing both is safe.
 * Returns a cleanup function.
 */
export function installVitalsFlush(win: FlushTarget, vitals: { flush: () => void }) {
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
