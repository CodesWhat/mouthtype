import QtQuick

// A stand-in for Panel.qml's state, so MouthtypeShell and every page render and run without Quickshell. It has the same
// property names and functions the pages use as `host`. run() and pageRequested calls are recorded, never executed.
QtObject {
  id: host

  property var shellRef: null
  property var ran: []

  property bool serviceRunning: true
  property string sessionState: "idle"
  property bool hasTranscript: true
  property var recent: []
  property var saved: []
  property var config: ({})
  property int wordsToday: 0
  property bool soundsEnabled: true
  property bool autostartEnabled: true
  property string shortcutMode: "hold"
  property string shortcutKeys: "F10"
  property string transcript: ""
  property string transcriptId: "t1"
  property string notice: ""
  property string errorText: ""
  property var capabilities: ({ file_transcription: true })
  property var pillPrefs: ({ enabled: true, skin: "classic", size: 1 })
  property var cleanupInfo: ({ models: {}, setup: null, service: null })
  property var history: ({ takes: 0, maximum: 200 })
  property var fontPrefs: ({ preset: "default", family: "", overrides: {} })
  property var versions: ({ plugin: "1.3.0", app: "0.4.0" })
  property var lastState: ({})
  property var pendingDraft: null
  property string transcriptFont: "sans-serif"
  property string pillFont: "sans-serif"
  property var fileImport: ({ state: "off" })
  property string importText: ""
  property string importTextFor: ""
  readonly property int savedCount: saved.length
  readonly property bool canImportFiles: !!(capabilities && capabilities.file_transcription)
  readonly property bool importActive: fileImport.state === "preparing" || fileImport.state === "transcribing" || fileImport.state === "cancelling"
  readonly property bool importHasResult: fileImport.state === "finished" || fileImport.state === "empty"
  readonly property bool importRetained: !importActive && !importHasResult && fileImport.retained === true
  readonly property bool importCanExport: fileImport.state === "finished" || importRetained

  function run(args) { ran = ran.concat([args]) }
  function close() { run(["close"]) }
  function showRecording(id) { run(["recover", id]) }
  function loadImportText() { importText = importText }
  function openPage(name) { if (shellRef) shellRef.navigate(name) }
  function importLabel() {
    switch (fileImport.state) {
      case "preparing": return "Preparing audio…"
      case "transcribing": return "Transcribing · 1:23…"
      case "finished": return "Finished · 1:23"
      case "failed": return "Failed"
      default: return "No file chosen"
    }
  }

  function seconds(hoursAgo) { return Date.now() / 1000 - hoursAgo * 3600 }

  // A full, healthy install.
  function populated() {
    serviceRunning = true
    sessionState = "idle"
    hasTranscript = true
    soundsEnabled = true
    autostartEnabled = true
    shortcutMode = "hold"
    shortcutKeys = "F10"
    pillPrefs = { enabled: true, skin: "classic", size: 1 }
    versions = { plugin: "1.3.0", app: "0.4.0" }
    notice = ""
    errorText = ""
    recent = [
      { id: "a", transcript: true, audio: true, preview: "Can we push the sync to 10 tomorrow", mtime: seconds(0.2) },
      { id: "b", transcript: true, audio: true, preview: "Thanks Priya, the signed build is", mtime: seconds(1.5) },
      { id: "c", transcript: true, audio: false, preview: "TODO: the glass pill falls back to", mtime: seconds(2.5) },
      { id: "d", transcript: true, audio: true, preview: "Remind me to book flights for the", mtime: seconds(27) },
      { id: "e", transcript: true, audio: true, preview: "running ten late, order me whatever", mtime: seconds(29) }
    ]
    saved = [{ id: "f", transcript: false, audio: true, preview: "", mtime: seconds(3.5) }]
    config = { delivery_mode: "paste", cleanup: "fast", maximum_recording_seconds: 60, notifications: true,
               history_keep: null, maximum_recovery_takes: 200, audio_retention_days: 30, allowed_classes: [] }
    wordsToday = 412
    history = { takes: 6, maximum: 200 }
    cleanupInfo = { models: { fast: "prepared", thorough: "missing" }, setup: null,
                    service: { level: "fast", model: { state: "ready" }, last_outcome: "ok", last_ms: 812 } }
    transcript = "Thanks Priya, the signed build is up. Release notes are in the PR, and the Hyprland notes moved to the Linux guide."
  }

  // First run: nothing recorded, models absent, a download in flight, a failed import.
  function empty() {
    recent = []
    saved = []
    config = { delivery_mode: "recover", cleanup: "off", maximum_recording_seconds: 30, notifications: false,
               history_keep: 20, maximum_recovery_takes: 500, audio_retention_days: null, allowed_classes: [] }
    wordsToday = 0
    hasTranscript = false
    soundsEnabled = false
    autostartEnabled = false
    shortcutMode = "off"
    shortcutKeys = ""
    history = { takes: 0, maximum: 200 }
    cleanupInfo = { models: {}, setup: { state: "downloading", level: "thorough", bytes_done: 1000000000, bytes_total: 2497281120 }, service: null }
    versions = { plugin: "1.3.0", app: null }
    pillPrefs = { enabled: true, skin: "hifi", size: 2 }
  }
}
