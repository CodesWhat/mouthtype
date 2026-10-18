const link = document.querySelector("[data-download]");
const status = document.querySelector("[data-download-status]");
let timer;
let requested = false;
const platform = navigator.userAgentData?.platform || navigator.platform || "";
const mobile = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
const automaticMac = /^mac/i.test(platform) && !mobile && (navigator.maxTouchPoints ?? 0) < 2;
const linux = /linux/i.test(platform) && !mobile;

function markRequested() {
  requested = true;
  clearInterval(timer);
  status.textContent = "Download requested. Use Download now to retry.";
}

function startCountdown() {
  if (!automaticMac || requested) {
    if (!requested) status.textContent = linux
      ? "On Linux? Open the Linux test-client guide. The Mac ZIP won’t download automatically."
      : "Choose your platform below. Download now gets the Mac release candidate.";
    return;
  }
  clearInterval(timer);
  let remaining = 5;
  status.textContent = `Your download starts in ${remaining} seconds.`;
  timer = setInterval(() => {
    remaining -= 1;
    if (remaining === 0) {
      markRequested();
      window.location.assign(link.href);
    } else {
      status.textContent = `Your download starts in ${remaining} ${remaining === 1 ? "second" : "seconds"}.`;
    }
  }, 1000);
}

link.addEventListener("click", markRequested);
window.addEventListener("pagehide", () => clearInterval(timer));
window.addEventListener("pageshow", (event) => {
  if (event.persisted && !requested) startCountdown();
});
startCountdown();
