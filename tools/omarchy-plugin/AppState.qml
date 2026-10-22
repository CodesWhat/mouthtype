import QtQuick
import MouthtypePlatform
import "Fonts.js" as Fonts

// The Mouthtype state model: the last `control.py state` reply, the single-flight control.py processes, the page request
// queue and the file-import text. It imports only QtQuick and MouthtypePlatform, so the Omarchy bar (Panel.qml) and the Qt
// host both run it unchanged. MouthtypeShell and the pages receive this object as `host`.
//
// The embedding host sets `helper` (path of control.py), `opened`, `shell` (the MouthtypeShell) and `fallbackFont`, and
// answers `openRequested`/`closeRequested`.
Item {
  id: root

  property string helper: ""
  property bool opened: false
  property var shell: null
  property string fallbackFont: ""
  readonly property string runtime: Platform.env("XDG_RUNTIME_DIR")

  signal openRequested()
  signal closeRequested()

  // The Mac opens the mouth through recording0/1/2 with the pill's meter level. Service.qml owns the meter and writes the
  // frame (0..2, already capped at 15 fps) to $XDG_RUNTIME_DIR/mouthtype/bar-lips. Without it, recording shows the middle frame.
  property int lipsFrame: 1
  readonly property string glyphState: !serviceRunning ? "unavailable"
    : sessionState === "recording" ? "recording" + lipsFrame
    : sessionState === "idle" ? "idle" : "processing"
  property bool hasTranscript: false
  readonly property int savedCount: saved.length

  property bool serviceRunning: false
  property string sessionState: "off"
  property var recent: []
  property var saved: []
  property var config: ({})
  property int wordsToday: 0
  property bool soundsEnabled: false
  property bool autostartEnabled: false
  property string shortcutMode: "off"
  property string shortcutKeys: ""
  property string transcript: ""
  property string transcriptId: ""
  property string notice: ""
  property string errorText: ""
  property var capabilities: ({})
  property var pillPrefs: ({ enabled: true, skin: "classic", size: 1 })
  property var cleanupInfo: ({ models: {}, setup: null, service: null })
  property var history: ({ takes: 0, maximum: 200 })
  property var fontPrefs: ({ preset: "default", family: "", overrides: {} })
  property var versions: ({ plugin: null, app: null })
  // The last `control.py state` reply, merged. The shell hands it to data pages as backend.state.
  property var lastState: ({})
  readonly property string transcriptFont: Fonts.family({ font: fontPrefs }, "transcript", fallbackFont)
  readonly property string pillFont: Fonts.family({ font: fontPrefs }, "pill", fallbackFont)
  property var fileImport: ({ state: "off" })
  property string importText: ""
  property string importTextFor: ""
  readonly property bool canImportFiles: !!(capabilities && capabilities.file_transcription)
  readonly property bool importActive: fileImport.state === "preparing" || fileImport.state === "transcribing" || fileImport.state === "cancelling"
  readonly property bool importHasResult: fileImport.state === "finished" || fileImport.state === "empty"
  readonly property bool importRetained: !importActive && !importHasResult && fileImport.retained === true
  readonly property bool importCanExport: fileImport.state === "finished" || importRetained

  // One control.py process of each kind at a time, as before.
  property bool stateBusy: false
  property bool actionBusy: false
  property bool recoverBusy: false
  property bool importBusy: false
  property bool pageBusy: false
  property string pagePending: ""
  property var pageQueue: []
  property var lipsWatch: null

  function clock(seconds) {
    if (seconds === null || seconds === undefined || isNaN(Number(seconds))) return ""
    var total = Math.round(Number(seconds))
    var minutes = Math.floor(total / 60)
    var rest = total % 60
    return minutes + ":" + (rest < 10 ? "0" : "") + rest
  }

  function importLabel() {
    var length = clock(fileImport.duration_seconds)
    switch (fileImport.state) {
      case "preparing": return "Preparing audio…"
      case "transcribing": return "Transcribing" + (length ? " · " + length : "") + "…"
      case "cancelling": return "Cancelling…"
      case "finished": return "Finished" + (length ? " · " + length : "")
      case "empty": return "No speech was recognized"
      case "cancelled": return "Cancelled"
      case "failed": return "Failed"
      case "off": return "Mouthtype is not running"
      default: return "No file chosen"
    }
  }

  function open() { openRequested() }
  function close() { closeRequested() }

  function absorb(result) {
    if (result.running !== undefined) serviceRunning = result.running === true
    if (result.state !== undefined) sessionState = String(result.state || "off")
    if (result.recent !== undefined) recent = result.recent || []
    if (result.has_transcript !== undefined) hasTranscript = result.has_transcript === true
    if (result.saved !== undefined) saved = result.saved || []
    if (result.config !== undefined) config = result.config || ({})
    if (result.words_today !== undefined) wordsToday = Number(result.words_today) || 0
    if (result.sounds !== undefined) soundsEnabled = result.sounds === true
    if (result.autostart !== undefined) autostartEnabled = result.autostart === true
    if (result.shortcut !== undefined) shortcutMode = String(result.shortcut || "off")
    if (result.shortcut_keys !== undefined) shortcutKeys = String(result.shortcut_keys || "")
    if (result.capabilities !== undefined) capabilities = result.capabilities || ({})
    if (result.pill !== undefined) pillPrefs = result.pill || ({ enabled: true, skin: "classic", size: 1 })
    if (result.cleanup !== undefined) cleanupInfo = result.cleanup || ({ models: {}, setup: null, service: null })
    if (result.history !== undefined) history = result.history || ({ takes: 0, maximum: 200 })
    if (result.font !== undefined) fontPrefs = result.font || ({})
    if (result.versions !== undefined) versions = result.versions || ({ plugin: null, app: null })
    if (result.file_import !== undefined) {
      fileImport = result.file_import || ({ state: "off" })
      if (!importHasResult || (fileImport.id || "") !== importTextFor) { importText = ""; importTextFor = "" }
      if (shell && shell.page === "import" && importHasResult && importTextFor !== (fileImport.id || "")) loadImportText()
    }
    if (result.message) notice = String(result.message)
    if (result.error) errorText = String(result.error)
    if (result.page) { navigate(String(result.page)); if (!opened) open() }
  }

  function navigate(name) {
    if (shell) shell.navigate(name)
  }

  function loadImportText() {
    if (importBusy) return
    importBusy = true
    Platform.run([helper, "import-result"], function(out, code) {
      importBusy = false
      try {
        var result = JSON.parse(String(out || "{}"))
        if (result.error) errorText = String(result.error)
        else { importText = String(result.text || ""); importTextFor = String(fileImport.id || "") }
      } catch (e) { errorText = "Could not read the file transcript" }
    })
  }

  function refresh() {
    if (stateBusy) return
    stateBusy = true
    Platform.run([helper, "state"], function(out, code) {
      stateBusy = false
      try {
        var reply = JSON.parse(String(out || "{}"))
        lastState = reply
        absorb(reply)
      }
      catch (e) { errorText = "Could not read Mouthtype status" }
    })
  }

  function run(args) {
    if (actionBusy) return
    errorText = ""
    notice = ""
    actionBusy = true
    Platform.run([helper].concat(args), function(out, code) {
      actionBusy = false
      try { absorb(JSON.parse(String(out || "{}"))) }
      catch (e) { errorText = "Mouthtype action failed" }
      refresh()
    })
  }

  function showRecording(identity) {
    if (recoverBusy) return
    errorText = ""
    transcriptId = identity
    recoverBusy = true
    Platform.run([helper, "recover", identity], function(out, code) {
      recoverBusy = false
      try {
        var result = JSON.parse(String(out || "{}"))
        if (result.error) errorText = String(result.error)
        else { transcript = String(result.text || ""); navigate("transcript") }
      } catch (e) { errorText = "Could not read saved transcript" }
    })
  }

  // Old menu page names still work: the shell maps them onto the sidebar pages and the Settings modal.
  function openPage(name) {
    errorText = ""
    notice = ""
    navigate(name)
  }

  // Data pages (Stats, Dictionary, Transforms, Style) send control.py verbs through here, one at a time, in order.
  function pageRequest(command, args) {
    pageQueue = pageQueue.concat([{ command: command, args: args }])
    runNextPage()
  }

  function runNextPage() {
    if (pageBusy || pageQueue.length === 0) return
    var next = pageQueue[0]
    pageQueue = pageQueue.slice(1)
    pagePending = next.command
    pageBusy = true
    if (shell) shell.pageBusy = true
    Platform.run([helper, next.command].concat(next.args.map(String)), function(out, code) {
      try { if (shell) shell.pageResult(pagePending, JSON.parse(String(out || "{}"))) }
      catch (e) { if (shell) shell.pageFailed("Mouthtype page request failed") }
      pageBusy = false
      if (shell) shell.pageBusy = false
      refresh()
      runNextPage()
    })
  }

  onOpenedChanged: {
    if (opened) refresh()
    else { navigate("home"); transcript = "" }
  }
  onSessionStateChanged: if (sessionState !== "recording") lipsFrame = 1

  Component.onCompleted: {
    refresh()
    if (runtime !== "") lipsWatch = Platform.watch(runtime + "/mouthtype/bar-lips", function(text) {
      var frame = parseInt(String(text || "").trim(), 10)
      if (sessionState === "recording" && frame >= 0 && frame <= 2) lipsFrame = frame
    })
  }
  Component.onDestruction: if (lipsWatch) lipsWatch.destroy()

  Timer {
    interval: 1500
    running: root.opened || root.serviceRunning
    repeat: true
    onTriggered: root.refresh()
  }
}
