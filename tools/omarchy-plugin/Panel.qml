import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "design"
import "Fonts.js" as Fonts

// The bar widget and panel host. It owns the state, the control.py processes and the IPC handler; MouthtypeShell draws the
// window (sidebar, pages, Settings modal) and the files in pages/ draw each page. Pages receive this object as `host`.
Panel {
  id: root
  moduleName: "dstahl.mouthtype"
  ipcTarget: "dstahl.mouthtype"
  manageIpc: false

  readonly property string helper: Quickshell.env("HOME") + "/.config/omarchy/plugins/dstahl.mouthtype/control.py"
  // The Mac opens the mouth through recording0/1/2 with the pill's meter level. Service.qml owns the meter and writes the
  // frame (0..2, already capped at 15 fps) to $XDG_RUNTIME_DIR/mouthtype/bar-lips. Without it, recording shows the middle frame.
  property int lipsFrame: 1
  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR")
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
  property bool welcomed: false
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
  // A recovered sheet draft picked on Home. The Dictionary or Transforms page takes it when it opens and sets this back to null.
  property var pendingDraft: null
  // The last `control.py state` reply, merged. The shell hands it to data pages as backend.state.
  property var lastState: ({})
  readonly property string transcriptFont: Fonts.family({ font: fontPrefs }, "transcript", Style.font.family)
  readonly property string pillFont: Fonts.family({ font: fontPrefs }, "pill", Style.font.family)
  property var fileImport: ({ state: "off" })
  property string importText: ""
  property string importTextFor: ""
  readonly property bool canImportFiles: !!(capabilities && capabilities.file_transcription)
  readonly property bool importActive: fileImport.state === "preparing" || fileImport.state === "transcribing" || fileImport.state === "cancelling"
  readonly property bool importHasResult: fileImport.state === "finished" || fileImport.state === "empty"
  readonly property bool importRetained: !importActive && !importHasResult && fileImport.retained === true
  readonly property bool importCanExport: fileImport.state === "finished" || importRetained

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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
    if (result.welcomed !== undefined) welcomed = result.welcomed === true
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
      if (shellView.page === "import" && importHasResult && importTextFor !== (fileImport.id || "")) loadImportText()
    }
    if (result.message) notice = String(result.message)
    if (result.error) errorText = String(result.error)
    if (result.page) { shellView.navigate(String(result.page)); if (!opened) open() }
  }

  function loadImportText() {
    if (importProc.running) return
    importProc.running = true
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function run(args) {
    if (actionProc.running) return
    errorText = ""
    notice = ""
    actionProc.command = [root.helper].concat(args)
    actionProc.running = true
  }

  function showRecording(identity) {
    if (recoverProc.running) return
    errorText = ""
    transcriptId = identity
    recoverProc.command = [root.helper, "recover", identity]
    recoverProc.running = true
  }

  // Old menu page names still work: the shell maps them onto the sidebar pages and the Settings modal.
  function openPage(name) {
    errorText = ""
    notice = ""
    shellView.navigate(name)
  }

  // Data pages (Stats, Dictionary, Transforms, Style) send control.py verbs through here, one at a time, in order.
  property var pageQueue: []

  function pageRequest(command, args) {
    pageQueue = pageQueue.concat([{ command: command, args: args }])
    runNextPage()
  }

  function runNextPage() {
    if (pageProc.running || pageQueue.length === 0) return
    var next = pageQueue[0]
    pageQueue = pageQueue.slice(1)
    pageProc.pending = next.command
    pageProc.command = [root.helper, next.command].concat(next.args.map(String))
    shellView.pageBusy = true
    pageProc.running = true
  }

  onOpenedChanged: {
    if (opened) refresh()
    else { shellView.navigate("home"); transcript = "" }
  }
  Component.onCompleted: refresh()

  Timer {
    interval: 1500
    running: root.opened || root.serviceRunning
    repeat: true
    onTriggered: root.refresh()
  }

  onSessionStateChanged: if (sessionState !== "recording") lipsFrame = 1

  FileView {
    path: root.runtime === "" ? "" : root.runtime + "/mouthtype/bar-lips"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var frame = parseInt(String(text() || "").trim(), 10)
      if (root.sessionState === "recording" && frame >= 0 && frame <= 2) root.lipsFrame = frame
    }
  }

  Process {
    id: stateProc
    command: [root.helper, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var reply = JSON.parse(String(text || "{}"))
          root.lastState = reply
          root.absorb(reply)
        }
        catch (e) { root.errorText = "Could not read Mouthtype status" }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.absorb(JSON.parse(String(text || "{}"))) }
        catch (e) { root.errorText = "Mouthtype action failed" }
        root.refresh()
      }
    }
  }

  Process {
    id: recoverProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(String(text || "{}"))
          if (result.error) root.errorText = String(result.error)
          else { root.transcript = String(result.text || ""); shellView.navigate("transcript") }
        } catch (e) { root.errorText = "Could not read saved transcript" }
      }
    }
  }

  Process {
    id: importProc
    command: [root.helper, "import-result"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(String(text || "{}"))
          if (result.error) root.errorText = String(result.error)
          else { root.importText = String(result.text || ""); root.importTextFor = String(root.fileImport.id || "") }
        } catch (e) { root.errorText = "Could not read the file transcript" }
      }
    }
  }

  Process {
    id: pageProc
    property string pending: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { shellView.pageResult(pageProc.pending, JSON.parse(String(text || "{}"))) }
        catch (e) { shellView.pageFailed("Mouthtype page request failed") }
        shellView.pageBusy = false
        root.refresh()
        root.runNextPage()
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function openPage(name: string): void { root.openPage(name); if (!root.opened) root.open() }
    function startCapture(): void { if (!root.opened) root.open(); shellView.beginCapture() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: Style.bar.iconSlot
    tooltipText: "Mouthtype · " + (root.serviceRunning ? root.sessionState : "off")
    active: root.sessionState === "recording"
    Image {
      id: statusGlyph
      anchors.centerIn: parent
      width: Style.space(16)
      height: Style.space(15)
      source: Qt.resolvedUrl("assets/glyph-" + root.glyphState + "@2x.png")
      sourceSize.width: 32
      sourceSize.height: 30
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }
    MultiEffect {
      anchors.fill: statusGlyph
      source: statusGlyph
      colorization: 1.0
      colorizationColor: root.sessionState === "recording"
        ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    }
    onPressed: function(code) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    padding: 0
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(900))
    contentHeight: panel.fittedContentHeight(Style.space(620), Style.space(620))

    Rectangle {
      anchors.fill: parent
      radius: Style.space(9)
      color: Theme.bg
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: shellView.editing
      onCloseRequested: { if (!shellView.dismissLayer()) root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      MouthtypeShell {
        id: shellView
        anchors.fill: parent
        host: root
        onPageRequested: function(command, args) { root.pageRequest(command, args) }
      }
    }
  }
}
