// The docs moved to https://docs.mouthtype.app. This maps each old /docs/#anchor to the
// matching page and anchor there. Loaded as a same-origin script, so the site CSP
// (script-src 'self') allows it. Without JavaScript the page's meta refresh and link apply.
(function () {
  var base = "https://docs.mouthtype.app";
  var map = {
    builds: "/getting-started/",
    shortcuts: "/dictating/#change-the-shortcut",
    "fn-key": "/troubleshooting/#fn-doesnt-start-dictation-or-the-emoji-picker-opens",
    "recording-options": "/dictating/#choose-a-microphone",
    "file-transcription": "/transcribe-audio-files/",
    cleanup: "/cleanup-and-style/",
    "spellings-phrases": "/dictionary/",
    "recent-stats": "/reference/settings/",
    "learned-corrections": "/dictionary/#suggestions",
    "advanced-writing": "/reference/settings/",
    recovery: "/dictating/#when-a-paste-doesnt-land",
    updates: "/getting-started/install-notes/#updates",
    "local-data": "/privacy-and-data/",
    permissions: "/getting-started/#allow-microphone-and-accessibility",
    troubleshooting: "/troubleshooting/",
    "known-limits": "/reference/known-limits/",
    linux: "/linux/",
  };
  var id = decodeURIComponent(window.location.hash.replace(/^#/, ""));
  var target = Object.prototype.hasOwnProperty.call(map, id) ? map[id] : "/";
  window.location.replace(base + target);
})();
