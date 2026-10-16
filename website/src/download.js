const link = document.querySelector("[data-download]");
const status = document.querySelector("[data-download-status]");
let timer;
let requested = false;

function markRequested() {
  requested = true;
  clearInterval(timer);
  status.textContent = "Download requested. Use Download now to retry.";
}

function startCountdown() {
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
