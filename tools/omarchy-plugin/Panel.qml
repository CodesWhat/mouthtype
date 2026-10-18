import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Fonts.js" as Fonts

Panel {
  id: root
  moduleName: "dstahl.mouthtype"
  ipcTarget: "dstahl.mouthtype"
  manageIpc: false

  readonly property string helper: Quickshell.env("HOME") + "/.config/omarchy/plugins/dstahl.mouthtype/control.py"
  readonly property string glyphState: !serviceRunning ? "unavailable"
    : sessionState === "recording" ? "recording"
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
  property string shortcutDraft: ""
  property bool capturing: false
  property string page: "menu"
  property string classDraft: ""
  property string transcript: ""
  property string transcriptId: ""
  property string notice: ""
  property string errorText: ""
  property var capabilities: ({})
  property var pillPrefs: ({ enabled: true, skin: "classic", size: 1 })
  property var cleanupInfo: ({ models: {}, setup: null, service: null })
  property var fontPrefs: ({ preset: "default", family: "", overrides: {} })
  property string familyDraft: ""
  property string overrideRole: "menu"
  property string overrideDraft: ""
  readonly property string menuFont: Fonts.family({ font: fontPrefs }, "menu", Style.font.family)
  readonly property string transcriptFont: Fonts.family({ font: fontPrefs }, "transcript", Style.font.family)
  readonly property string pillFont: Fonts.family({ font: fontPrefs }, "pill", Style.font.family)
  property var fileImport: ({ state: "off" })
  property string importText: ""
  property string importTextFor: ""
  readonly property bool canImportFiles: !!(capabilities && capabilities.file_transcription)
  readonly property bool importActive: fileImport.state === "preparing" || fileImport.state === "transcribing" || fileImport.state === "cancelling"
  readonly property bool importHasResult: fileImport.state === "finished" || fileImport.state === "empty"

  function hyprlandKeyName(event) {
    var k = event.key
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(65 + (k - Qt.Key_A))
    if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(48 + (k - Qt.Key_0))
    if (k >= Qt.Key_F1 && k <= Qt.Key_F24) return "F" + (1 + (k - Qt.Key_F1))
    var named = {}
    named[Qt.Key_Space] = "space"; named[Qt.Key_Return] = "Return"; named[Qt.Key_Enter] = "Return"; named[Qt.Key_Tab] = "Tab"
    named[Qt.Key_Backspace] = "BackSpace"; named[Qt.Key_Delete] = "Delete"; named[Qt.Key_Insert] = "Insert"; named[Qt.Key_Home] = "Home"
    named[Qt.Key_End] = "End"; named[Qt.Key_PageUp] = "Page_Up"; named[Qt.Key_PageDown] = "Page_Down"; named[Qt.Key_Print] = "Print"
    named[Qt.Key_Pause] = "Pause"; named[Qt.Key_ScrollLock] = "Scroll_Lock"; named[Qt.Key_Menu] = "Menu"; named[Qt.Key_Up] = "Up"
    named[Qt.Key_Down] = "Down"; named[Qt.Key_Left] = "Left"; named[Qt.Key_Right] = "Right"; named[Qt.Key_QuoteLeft] = "grave"
    named[Qt.Key_Minus] = "minus"; named[Qt.Key_Equal] = "equal"; named[Qt.Key_BracketLeft] = "bracketleft"; named[Qt.Key_BracketRight] = "bracketright"
    named[Qt.Key_Semicolon] = "semicolon"; named[Qt.Key_Apostrophe] = "apostrophe"; named[Qt.Key_Comma] = "comma"; named[Qt.Key_Period] = "period"
    named[Qt.Key_Slash] = "slash"; named[Qt.Key_Backslash] = "backslash"
    return named[k] || ""
  }

  property string pendingModifier: ""

  // Left/right modifier keysyms by evdev scan code (X keycode), so a bare Right Control can be chosen.
  function modifierKeysym(event) {
    var byCode = { 37: "Control_L", 105: "Control_R", 50: "Shift_L", 62: "Shift_R", 64: "Alt_L", 108: "Alt_R", 133: "Super_L", 134: "Super_R" }
    if (byCode[event.nativeScanCode]) return byCode[event.nativeScanCode]
    if (event.key === Qt.Key_Control) return "Control_L"
    if (event.key === Qt.Key_Shift) return "Shift_L"
    if (event.key === Qt.Key_Alt) return "Alt_L"
    if (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L) return "Super_L"
    if (event.key === Qt.Key_Super_R) return "Super_R"
    return ""
  }

  function releaseShortcut(event) {
    if (!capturing) return
    var keysym = modifierKeysym(event)
    if (keysym !== "" && pendingModifier === keysym) {
      // A modifier pressed and released on its own becomes the key, with its own modifier implied.
      var mod = keysym.indexOf("Control") === 0 ? "CTRL" : keysym.indexOf("Shift") === 0 ? "SHIFT" : keysym.indexOf("Alt") === 0 ? "ALT" : "SUPER"
      shortcutDraft = mod + " + " + keysym
      capturing = false
    }
    pendingModifier = ""
    event.accepted = true
  }

  function captureShortcut(event) {
    if (event.isAutoRepeat) { event.accepted = true; return }
    if (event.key === Qt.Key_Escape) { capturing = false; pendingModifier = ""; event.accepted = true; return }
    var keysym = modifierKeysym(event)
    if (keysym !== "") { pendingModifier = keysym; event.accepted = true; return }
    if (event.key === Qt.Key_AltGr || event.key === Qt.Key_CapsLock) { event.accepted = true; return }
    pendingModifier = ""
    var name = hyprlandKeyName(event)
    if (name === "") { event.accepted = true; return }
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    parts.push(name)
    shortcutDraft = parts.join(" + ")
    capturing = false
    event.accepted = true
  }

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
    if (result.shortcut !== undefined) shortcutMode = String(result.shortcut || "off")
    if (result.shortcut_keys !== undefined) shortcutKeys = String(result.shortcut_keys || "")
    if (result.capabilities !== undefined) capabilities = result.capabilities || ({})
    if (result.pill !== undefined) pillPrefs = result.pill || ({ enabled: true, skin: "classic", size: 1 })
    if (result.cleanup !== undefined) cleanupInfo = result.cleanup || ({ models: {}, setup: null, service: null })
    if (result.font !== undefined) { fontPrefs = result.font || ({}); familyDraft = String(fontPrefs.family || "") }
    if (result.file_import !== undefined) {
      fileImport = result.file_import || ({ state: "off" })
      if (!importHasResult || (fileImport.id || "") !== importTextFor) { importText = ""; importTextFor = "" }
      if (page === "import" && importHasResult && importTextFor !== (fileImport.id || "")) loadImportText()
    }
    if (result.message) notice = String(result.message)
    if (result.error) errorText = String(result.error)
    if (result.page) { page = String(result.page); if (!opened) open() }
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

  function openPage(name) {
    errorText = ""
    notice = ""
    page = name
    if (name === "delivery")
      classDraft = config.allowed_classes && config.allowed_classes.length ? config.allowed_classes[0] : ""
    if (name === "shortcut") { shortcutDraft = shortcutKeys; capturing = false }
    if (name === "fonts") { familyDraft = String(fontPrefs.family || ""); overrideDraft = String((fontPrefs.overrides || {})[overrideRole] || "") }
  }

  onOpenedChanged: {
    if (opened) refresh()
    else { page = "menu"; transcript = "" }
  }
  Component.onCompleted: refresh()

  Timer {
    interval: 1500
    running: root.opened || root.serviceRunning
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: [root.helper, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.absorb(JSON.parse(String(text || "{}"))) }
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
          else { root.transcript = String(result.text || ""); root.page = "transcript" }
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

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function openPage(name: string): void { root.openPage(name); if (!root.opened) root.open() }
    function startCapture(): void { root.openPage("shortcut"); if (!root.opened) root.open(); root.capturing = true; root.pendingModifier = ""; shortcutCapture.forceActiveFocus() }
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
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(1000))

    Rectangle {
      anchors.fill: parent
      radius: Style.space(9)
      color: "#D7D6D2"
    }

  PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: classField.activeFocus || importField.activeFocus || familyField.activeFocus || overrideField.activeFocus || shortcutField.activeFocus || root.capturing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: content
          width: scroll.width
          spacing: 0

          Column {
            visible: root.page === "menu"
            width: parent.width
            spacing: 0

            Item {
              width: parent.width
              height: Style.space(50)
              Text {
                x: Style.space(30); y: Style.space(8)
                text: "Mouthtype 0.1.0-alpha.8 · Linux"
                color: "#777775"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                x: Style.space(30); y: Style.space(27)
                text: "Parakeet TDT 0.6B v3 prepared"
                color: "#8A8A88"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: "Session: " + (root.serviceRunning ? root.sessionState : "off") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: "Delivery: " + (root.config.delivery_mode === "paste" ? "pasted into the active window" : root.config.delivery_mode === "type" ? "guarded typing" : "saved locally") }
            MenuDivider { width: parent.width }
            MenuRow {
              fontFamily: root.menuFont
              width: parent.width
              visible: root.sessionState !== "recording"
              label: "Start Dictation"
              enabled: root.sessionState === "off" || root.sessionState === "idle"
              onActivated: root.run(["start"])
            }
            MenuRow {
              fontFamily: root.menuFont
              width: parent.width
              visible: root.sessionState === "recording"
              label: "Stop Dictation"
              onActivated: root.run(["stop"])
            }
            MenuRow {
              fontFamily: root.menuFont
              width: parent.width
              visible: root.sessionState === "recording"
              label: "Cancel Dictation"
              onActivated: root.run(["cancel"])
            }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: root.wordsToday + (root.wordsToday === 1 ? " word today" : " words today") }
            Repeater {
              model: root.recent
              MenuRow {
              fontFamily: root.menuFont
                width: parent.width
                label: modelData.preview || "Empty dictation"
                onActivated: root.showRecording(modelData.id)
              }
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: !root.hasTranscript; enabled: false; label: "No dictations yet" }
            MenuDivider { width: parent.width }
            MenuRow {
              fontFamily: root.menuFont
              width: parent.width
              visible: root.canImportFiles
              label: root.importActive || root.importHasResult ? "Transcribe Audio File" : "Transcribe Audio File…"
              detail: root.importActive ? "Working" : root.importHasResult ? "Result" : ""
              chevron: root.importActive || root.importHasResult
              enabled: root.importActive || root.importHasResult || root.sessionState === "off" || root.sessionState === "idle"
              onActivated: {
                if (root.importActive || root.importHasResult) root.openPage("import")
                else root.run(["import-pick"])
              }
            }
            MenuDivider { width: parent.width; visible: root.canImportFiles }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Saved Recordings"; detail: root.savedCount ? String(root.savedCount) : ""; chevron: true; onActivated: root.openPage("saved") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Cleanup"; detail: root.config.cleanup === "basic" ? "Basic" : root.config.cleanup === "fast" ? "Fast" : root.config.cleanup === "thorough" ? "Thorough" : "Off"; chevron: true; onActivated: root.openPage("cleanup") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Paste Options"; detail: root.config.delivery_mode === "paste" ? "Paste" : root.config.delivery_mode === "type" ? "Type" : "Off"; chevron: true; onActivated: root.openPage("delivery") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Recording Settings"; chevron: true; onActivated: root.openPage("recording") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Floating Pill"; detail: !root.pillPrefs.enabled ? "Off" : root.pillPrefs.skin === "hifi" ? "Hi-Fi" : "Classic"; chevron: true; onActivated: root.openPage("pill") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Text Font"; detail: Fonts.summary({ font: root.fontPrefs }); chevron: true; onActivated: root.openPage("fonts") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Change Dictation Shortcut…"; chevron: true; onActivated: root.openPage("shortcut") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Paste Last"; enabled: root.hasTranscript && (root.config.delivery_mode === "type" || root.config.delivery_mode === "paste"); onActivated: { root.close(); Qt.callLater(function() { root.run(["paste-last"]) }) } }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Copy Last"; enabled: root.hasTranscript; onActivated: root.run(["copy"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Sounds"; checked: root.soundsEnabled; onActivated: root.run(["set-sounds", root.soundsEnabled ? "off" : "on"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Launch at Login"; checked: root.autostartEnabled; onActivated: root.run(["set-autostart", root.autostartEnabled ? "off" : "on"]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "How to Use Mouthtype…"; onActivated: root.openPage("help") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "About Mouthtype"; onActivated: root.openPage("about") }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Quit Mouthtype"; enabled: root.serviceRunning; onActivated: root.run(["shutdown"]) }
          }

          Column {
            id: cleanupPage
            visible: root.page === "cleanup"
            width: parent.width
            readonly property var models: root.cleanupInfo.models || ({})
            readonly property var setup: root.cleanupInfo.setup || null
            readonly property var service: root.cleanupInfo.service || null
            readonly property bool setupActive: !!setup && (setup.state === "preparing" || setup.state === "building" || setup.state === "downloading")
            function modelDetail(level) {
              if (service && service.level === level && service.model) {
                var s = service.model.state
                if (s === "ready") return "Ready"
                if (s === "loading") return "Loading…"
                if (s === "failed") return "Failed"
              }
              if (models[level] === "prepared") return "Prepared"
              return "Not prepared"
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Cleanup"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Off"; checked: root.config.cleanup === "off" || !root.config.cleanup; onActivated: root.run(["set-config", "cleanup", "off"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Basic"; checked: root.config.cleanup === "basic"; onActivated: root.run(["set-config", "cleanup", "basic"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Fast"; detail: cleanupPage.modelDetail("fast"); checked: root.config.cleanup === "fast"; enabled: cleanupPage.models.fast === "prepared"; onActivated: root.run(["set-config", "cleanup", "fast"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Thorough"; detail: cleanupPage.modelDetail("thorough"); checked: root.config.cleanup === "thorough"; enabled: cleanupPage.models.thorough === "prepared"; onActivated: root.run(["set-config", "cleanup", "thorough"]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: cleanupPage.models.fast !== "prepared"; enabled: !cleanupPage.setupActive; label: "Prepare Fast cleanup…"; detail: "≈480 MB"; onActivated: root.run(["cleanup-cleanupPage.setup", "fast"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: cleanupPage.models.thorough !== "prepared"; enabled: !cleanupPage.setupActive; label: "Prepare Thorough cleanup…"; detail: "≈2.5 GB"; onActivated: root.run(["cleanup-cleanupPage.setup", "thorough"]) }
            Text {
              visible: !!cleanupPage.setup && cleanupPage.setup.state !== "ready"
              x: Style.space(30); width: parent.width - Style.space(50)
              text: !cleanupPage.setup ? "" : cleanupPage.setup.state === "building" ? "Building the pinned llama.cpp server…"
                : cleanupPage.setup.state === "downloading" ? "Downloading and verifying the " + (cleanupPage.setup.level || "") + " model…"
                : cleanupPage.setup.state === "preparing" ? "Preparing…"
                : cleanupPage.setup.state === "failed" ? "Preparation failed (" + (cleanupPage.setup.error || "error") + "). Check the cleanup cleanupPage.setup log." : ""
              color: cleanupPage.setup && cleanupPage.setup.state === "failed" ? "#B72F26" : "#4A4A49"; wrapMode: Text.Wrap
              font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Text {
              visible: !!(cleanupPage.service && cleanupPage.service.last_outcome && (root.config.cleanup === "fast" || root.config.cleanup === "thorough"))
              x: Style.space(30); width: parent.width - Style.space(50)
              text: cleanupPage.service && cleanupPage.service.last_outcome ? "Last take: " + (cleanupPage.service.last_outcome === "ok" ? "model text accepted" : cleanupPage.service.last_outcome === "guard-rejected" ? "kept Basic (guard)" : cleanupPage.service.last_outcome === "timeout" ? "kept Basic (over budget)" : cleanupPage.service.last_outcome === "skipped" ? "model skipped" : "kept Basic (model error)") + (cleanupPage.service.last_ms !== null && cleanupPage.service.last_ms !== undefined ? " · " + cleanupPage.service.last_ms + " ms" : "") : ""
              color: "#4A4A49"; wrapMode: Text.Wrap
              font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width - Style.space(40)
              x: Style.space(30)
              text: "Basic formats spoken punctuation, lists and paragraphs. Fast adds S1-mini by Superwhisper and Thorough adds Qwen3 4B, both local llama.cpp cleanupPage.models on the CPU with the Mac guard rules; when a model times out or changes meaning, the Basic text is kept."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "delivery"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Paste Options"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Save to recovery only"; checked: root.config.delivery_mode !== "type" && root.config.delivery_mode !== "paste"; onActivated: root.run(["set-config", "delivery", "recover"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Paste into the active window"; checked: root.config.delivery_mode === "paste"; onActivated: root.run(["set-config", "delivery", "paste"]) }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Pastes with the clipboard and Ctrl+V into the window that was active when you started speaking, then restores your previous text clipboard. Terminals get Ctrl+Shift+V and no multi-line pastes."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Type into one allowed app"; checked: root.config.delivery_mode === "type"; enabled: false }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Exact Hyprland window class:"
              color: "#4A4A49"; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            }
            TextField {
              id: classField
              x: Style.space(30); width: parent.width - Style.space(60)
              height: Style.space(30)
              text: root.classDraft
              onTextEdited: root.classDraft = text
              placeholderText: "e.g. org.gnome.TextEditor"
              color: "#252525"
              font.family: Style.font.family; font.pixelSize: Style.font.body
              background: Rectangle { color: "#F7F7F5"; radius: 4; border.color: "#A8A8A6" }
            }
            MenuRow {
              fontFamily: root.menuFont
              width: parent.width; label: "Enable guarded typing for this app"
              enabled: root.classDraft.trim() !== ""
              onActivated: root.run(["set-config", "delivery", "type", root.classDraft.trim()])
            }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Linux cannot detect password fields, so pasting and typing go wherever the cursor is. Type delivery is limited to this exact app class and single-line text; check the target before retrying an uncertain insertion."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "recording"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Recording Settings"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "30 second limit"; checked: root.config.maximum_recording_seconds === 30; onActivated: root.run(["set-config", "maximum_recording_seconds", "30"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "60 second limit"; checked: root.config.maximum_recording_seconds === 60; onActivated: root.run(["set-config", "maximum_recording_seconds", "60"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "120 second limit"; checked: root.config.maximum_recording_seconds === 120; onActivated: root.run(["set-config", "maximum_recording_seconds", "120"]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Desktop recording cues"; checked: root.config.notifications !== false; onActivated: root.run(["set-config", "notifications", root.config.notifications === false ? "on" : "off"]) }
          }

          Column {
            visible: root.page === "pill"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Floating Pill"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Show the pill while dictating"; checked: root.pillPrefs.enabled !== false; onActivated: root.run(["set-pill", "enabled", root.pillPrefs.enabled !== false ? "off" : "on"]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Classic"; checked: root.pillPrefs.skin !== "hifi"; onActivated: root.run(["set-pill", "skin", "classic"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Hi-Fi"; checked: root.pillPrefs.skin === "hifi"; onActivated: root.run(["set-pill", "skin", "hifi"]) }
            MenuDivider { width: parent.width; visible: root.pillPrefs.skin === "hifi" }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: root.pillPrefs.skin === "hifi"; label: "Standard size"; checked: root.pillPrefs.size !== 2; onActivated: root.run(["set-pill", "size", "1"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: root.pillPrefs.skin === "hifi"; label: "Large (2×)"; checked: root.pillPrefs.size === 2; onActivated: root.run(["set-pill", "size", "2"]) }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "The pill floats at the bottom of the focused display while you dictate: a level meter with cancel and stop, a wave while transcribing, then a short note. It never takes keyboard focus; only its two buttons are clickable."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "fonts"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Text Font"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Default"; detail: Style.font.family; checked: root.fontPrefs.preset === "default" || !root.fontPrefs.preset; onActivated: root.run(["set-font", "preset", "default"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Sans"; checked: root.fontPrefs.preset === "sans"; onActivated: root.run(["set-font", "preset", "sans"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Serif"; checked: root.fontPrefs.preset === "serif"; onActivated: root.run(["set-font", "preset", "serif"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Mono"; checked: root.fontPrefs.preset === "mono"; onActivated: root.run(["set-font", "preset", "mono"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Custom family"; checked: root.fontPrefs.preset === "custom"; enabled: false }
            TextField {
              id: familyField
              x: Style.space(30); width: parent.width - Style.space(60)
              height: Style.space(30)
              text: root.familyDraft
              onTextEdited: root.familyDraft = text
              onAccepted: root.run(["set-font", "family", root.familyDraft.trim()])
              placeholderText: "e.g. Inter, Iosevka, Noto Serif"
              color: "#252525"
              font.family: root.menuFont; font.pixelSize: Style.font.body
              background: Rectangle { color: "#F7F7F5"; radius: 4; border.color: "#A8A8A6" }
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Use this family"; enabled: root.familyDraft.trim() !== ""; onActivated: root.run(["set-font", "family", root.familyDraft.trim()]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: "Overrides by role" }
            Row {
              x: Style.space(30); spacing: Style.space(6)
              Repeater {
                model: ["menu", "transcript", "pill"]
                ControlButton {
                  required property string modelData
                  label: modelData === "menu" ? "Menu" : modelData === "transcript" ? "Transcript" : "Pill"
                  enabled: root.overrideRole !== modelData
                  onClicked: { root.overrideRole = modelData; root.overrideDraft = String((root.fontPrefs.overrides || {})[modelData] || "") }
                }
              }
            }
            Item { height: Style.space(6) }
            TextField {
              id: overrideField
              x: Style.space(30); width: parent.width - Style.space(60)
              height: Style.space(30)
              text: root.overrideDraft
              onTextEdited: root.overrideDraft = text
              onAccepted: root.run(["set-font", "override", root.overrideRole, root.overrideDraft.trim() || "-"])
              placeholderText: "Family for the " + root.overrideRole + " role, blank for the preset"
              color: "#252525"
              font.family: root.menuFont; font.pixelSize: Style.font.body
              background: Rectangle { color: "#F7F7F5"; radius: 4; border.color: "#A8A8A6" }
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Apply to " + root.overrideRole; onActivated: root.run(["set-font", "override", root.overrideRole, root.overrideDraft.trim() || "-"]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: "Preview" }
            Column {
              x: Style.space(30); width: parent.width - Style.space(50); spacing: Style.space(4)
              Text { width: parent.width; text: "Menu · Start Dictation"; color: "#252525"; font.family: root.menuFont; font.pixelSize: Style.font.body; elide: Text.ElideRight }
              Text { width: parent.width; text: "Transcript · The quick brown fox jumps over the lazy dog."; color: "#252525"; wrapMode: Text.Wrap; font.family: root.transcriptFont; font.pixelSize: Style.font.body }
              Rectangle {
                width: pillPreview.implicitWidth + Style.space(32); height: Style.space(28); radius: height / 2
                color: Qt.rgba(0x1A / 255, 0x1A / 255, 0x1A / 255, 0.96); border.color: "#4D4A42"
                Text { id: pillPreview; anchors.centerIn: parent; text: "Pill · Pasted"; color: "#FFFFEB"; font.family: root.pillFont; font.pixelSize: 13; font.weight: Font.Medium }
              }
            }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "These fonts apply to Mouthtype's own menu, transcript cards and the Classic pill. The Hi-Fi pill keeps its bitmap readout. The app you dictate into chooses the font for inserted text."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "shortcut"
            width: parent.width
            onVisibleChanged: if (!visible) root.capturing = false
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Dictation Shortcut"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Off"; checked: root.shortcutMode === "off"; onActivated: root.run(["set-shortcut", "off"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Press to toggle"; detail: root.shortcutMode === "toggle" ? root.shortcutKeys : ""; checked: root.shortcutMode === "toggle"; onActivated: root.run(["set-shortcut", "toggle", root.shortcutDraft.trim() || (root.shortcutMode === "toggle" ? root.shortcutKeys : "SUPER + ALT + M")]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Hold to talk"; detail: root.shortcutMode === "hold" ? root.shortcutKeys : ""; checked: root.shortcutMode === "hold"; onActivated: root.run(["set-shortcut", "hold", root.shortcutDraft.trim() || (root.shortcutMode === "hold" ? root.shortcutKeys : "F10")]) }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: "Key" }
            Item {
              id: shortcutCapture
              width: 1; height: 1
              focus: root.capturing
              Keys.onPressed: function(event) { root.captureShortcut(event) }
              Keys.onReleased: function(event) { root.releaseShortcut(event) }
              onFocusChanged: if (root.capturing && !activeFocus) forceActiveFocus()
            }
            MenuRow {
              fontFamily: root.menuFont; width: parent.width
              label: root.capturing ? "Press the keys now… (Esc cancels)" : "Press a new key combination…"
              onActivated: { root.capturing = !root.capturing; root.pendingModifier = ""; if (root.capturing) shortcutCapture.forceActiveFocus() }
            }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Or pick a modifier key on its own:"
              color: "#4A4A49"; font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Flow {
              x: Style.space(30); width: parent.width - Style.space(50); spacing: Style.space(6)
              Repeater {
                model: [["Right Ctrl", "CTRL + Control_R"], ["Left Ctrl", "CTRL + Control_L"], ["Right Alt", "ALT + Alt_R"], ["Left Alt", "ALT + Alt_L"],
                        ["Right Shift", "SHIFT + Shift_R"], ["Left Shift", "SHIFT + Shift_L"], ["Right Super", "SUPER + Super_R"], ["Left Super", "SUPER + Super_L"]]
                ControlButton {
                  required property var modelData
                  label: modelData[0]
                  enabled: root.shortcutDraft !== modelData[1]
                  onClicked: { root.capturing = false; root.shortcutDraft = modelData[1] }
                }
              }
            }
            Item { height: Style.space(4) }
            TextField {
              id: shortcutField
              x: Style.space(30); width: parent.width - Style.space(60)
              height: Style.space(30)
              text: root.shortcutDraft
              onTextEdited: root.shortcutDraft = text
              placeholderText: "e.g. SUPER + SHIFT + D, F8, Insert"
              color: "#252525"
              font.family: root.menuFont; font.pixelSize: Style.font.body
              background: Rectangle { color: "#F7F7F5"; radius: 4; border.color: root.capturing ? "#4F78C3" : "#A8A8A6"; border.width: root.capturing ? 2 : 1 }
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Use for press-to-toggle"; enabled: root.shortcutDraft.trim() !== ""; onActivated: root.run(["set-shortcut", "toggle", root.shortcutDraft.trim()]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Use for hold-to-talk"; enabled: root.shortcutDraft.trim() !== ""; onActivated: root.run(["set-shortcut", "hold", root.shortcutDraft.trim()]) }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Letters, digits, F-keys, named keys such as Insert or Page_Down, or a modifier key on its own, with optional SUPER, ALT, CTRL or SHIFT. Modifier keys pressed alone are not delivered to applications on desktops with an input method such as fcitx5, so choose them with the buttons or type them. A key Hyprland already binds is refused. A lone modifier also fires inside its own shortcuts: Right Ctrl as hold-to-talk will start and stop a take whenever you use Right Ctrl for Ctrl+C."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: root.menuFont; font.pixelSize: Style.font.bodySmall
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "saved"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Saved Recordings"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            Repeater {
              model: root.saved
              MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Retry speech for saved audio"; onActivated: root.run(["transcribe", modelData.id]) }
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: root.savedCount === 0; enabled: false; label: "No saved recordings" }
          }

          Column {
            visible: root.page === "import"
            width: parent.width
            onVisibleChanged: if (visible && root.importHasResult && root.importTextFor !== (root.fileImport.id || "")) root.loadImportText()
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Transcribe Audio File"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            MenuRow { fontFamily: root.menuFont; width: parent.width; enabled: false; label: root.importLabel(); detail: root.fileImport.format ? String(root.fileImport.format).toUpperCase() : "" }
            Text {
              visible: root.fileImport.state === "failed" && (root.fileImport.message || "") !== ""
              x: Style.space(30); width: parent.width - Style.space(50)
              text: root.fileImport.message || ""
              color: "#B72F26"; wrapMode: Text.Wrap
              font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: root.importActive; label: "Cancel"; enabled: root.fileImport.state !== "cancelling"; onActivated: root.run(["import-cancel"]) }
            Rectangle {
              visible: root.fileImport.state === "finished"
              x: Style.space(30); width: parent.width - Style.space(60)
              height: Math.min(Math.max(importField.contentHeight + Style.space(16), Style.space(40)), Style.space(260))
              radius: 4
              color: "#F7F7F5"
              border.color: "#A8A8A6"
              Flickable {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                contentWidth: width
                contentHeight: importField.contentHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                TextEdit {
                  id: importField
                  width: parent.width
                  text: root.importText !== "" ? root.importText : (root.fileImport.state === "finished" && root.importTextFor === "" ? "Loading…" : "")
                  readOnly: true
                  selectByMouse: true
                  selectByKeyboard: true
                  wrapMode: TextEdit.Wrap
                  color: "#252525"
                  selectionColor: "#4F78C3"
                  selectedTextColor: "#FFFFFF"
                  font.family: root.transcriptFont; font.pixelSize: Style.font.body
                }
              }
            }
            Item { height: Style.space(6); visible: root.fileImport.state === "finished" }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: root.importHasResult; enabled: root.fileImport.state === "finished"; label: "Copy"; onActivated: root.run(["import-copy"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: root.importHasResult; enabled: root.fileImport.state === "finished"; label: "Save Text…"; onActivated: root.run(["import-save"]) }
            MenuDivider { width: parent.width; visible: !root.importActive }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: !root.importActive; label: "Transcribe Another File…"; enabled: root.sessionState === "off" || root.sessionState === "idle"; onActivated: root.run(["import-pick"]) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; visible: !root.importActive && root.fileImport.state !== "idle" && root.fileImport.state !== "off"; label: "Clear Result"; onActivated: root.run(["import-forget"]) }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Files up to 10 minutes and 512 MB in WAV, AIFF or M4A. The result is the raw recognition: cleanup, saved spellings and phrases are not applied, nothing is pasted, and it is not added to Recent Dictations. Your original file is not changed."
              color: "#6F6F6D"; wrapMode: Text.Wrap
              font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "transcript"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  Recent Dictations"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: root.transcript
              color: "#252525"; wrapMode: Text.Wrap
              font.family: root.transcriptFont; font.pixelSize: Style.font.body
            }
            Item { height: Style.space(8) }
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "Copy Dictation"; onActivated: root.run(["copy", root.transcriptId]) }
          }

          Column {
            visible: root.page === "help"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  How to Use"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Choose Start Dictation, speak, then Stop Dictation. Your transcript is saved under Recent Dictations. Use Saved Recordings to retry audio after a speech error. Configure the shortcut, cleanup and delivery in this menu." + (root.canImportFiles ? " Transcribe Audio File… transcribes one WAV, AIFF or M4A file and shows the raw result to copy or save." : "")
              color: "#3A3A39"; wrapMode: Text.Wrap
              font.family: Style.font.family; font.pixelSize: Style.font.body
            }
            Item { height: Style.space(14) }
          }

          Column {
            visible: root.page === "about"
            width: parent.width
            MenuRow { fontFamily: root.menuFont; width: parent.width; label: "‹  About Mouthtype"; onActivated: root.openPage("menu") }
            MenuDivider { width: parent.width }
            Text {
              x: Style.space(30); width: parent.width - Style.space(50)
              text: "Mouthtype Linux 0.1.0-alpha.8 · experimental\nParakeet TDT 0.6B v3\n\n" + (root.canImportFiles ? "Audio file transcription is available from this menu. " : "This client cannot transcribe audio files. ") + "The floating pill, text font settings and Fast/Thorough cleanup are in this menu. Cleanup models are local llama.cpp builds on the CPU."
              color: "#3A3A39"; wrapMode: Text.Wrap
              font.family: Style.font.family; font.pixelSize: Style.font.body
            }
            Item { height: Style.space(14) }
          }

          Text {
            visible: root.notice !== "" || root.errorText !== ""
            x: Style.space(30); width: parent.width - Style.space(50)
            text: root.errorText || root.notice
            color: root.errorText ? "#B72F26" : "#4A4A49"
            wrapMode: Text.Wrap
            font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
          }
          Item { height: Style.space(7) }
        }
      }
    }
  }
}
