import QtQuick
import QtQuick.Window
import org.kde.layershell 1.0 as LayerShell
import MouthtypePlatform
import "../omarchy-plugin"
import "../omarchy-plugin/design"
import "../omarchy-plugin/PillModel.js" as Model

// The KDE pill: the Omarchy pill's controller (Service.qml) on a LayerShellQt overlay surface. The layer-shell attached
// properties put it above windows, bottom-centre, with no keyboard focus and no exclusive zone, so a take never moves the
// paste target. Hosts the Classic skin (ClassicPill.qml, unchanged) and the Hi-Fi skin (HifiPill.qml). Fed by the daemon's
// text-free state stream (`PillFeed`), skin and size from AppState.pillPrefs. Main.qml loads it only when
// Platform.isLayerShell, since the import above exists only where the org.kde.layershell QML module is installed.
Window {
  id: pill

  property var app: null

  readonly property var pillPrefs: app ? app.pillPrefs : ({})
  readonly property bool enabled: pillPrefs.enabled !== false
  readonly property string skin: pillPrefs.skin === "hifi" ? "hifi" : "classic"
  readonly property int hifiScale: pillPrefs.size === 2 ? 2 : 1
  property string deliveryMode: "recover"

  // Controller state: hidden, recording, processing, message.
  property string mode: "hidden"
  property string sessionState: "off"
  property var message: null
  property real elapsed: 0
  property real level: -120
  property var fractions: []
  property real processingStart: 0
  property real processingTime: 0
  property int generation: 0
  property var meter: new Model.Meter()
  readonly property bool showing: mode !== "hidden"
  readonly property bool showControls: mode === "recording"
  // Test hook: fires once the pill has been shown and has settled (the --pill-screenshot run).
  signal shown()

  LayerShell.Window.scope: "mouthtype-pill"
  LayerShell.Window.anchors: LayerShell.Window.AnchorBottom
  LayerShell.Window.layer: LayerShell.Window.LayerOverlay
  LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone
  LayerShell.Window.exclusionZone: 0
  LayerShell.Window.margins.bottom: 12

  flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus | Qt.Tool
  color: "transparent"
  screen: Platform.focusedScreen
  width: skin === "hifi" ? 146 * hifiScale + 48 : 360 + 48
  height: skin === "hifi" ? 32 * hifiScale + 24 : 100
  visible: showing && enabled

  function present(nextMode) {
    generation += 1
    mode = nextMode
  }

  function hide() {
    generation += 1
    mode = "hidden"
    message = null
    fractions = []
  }

  function showMessageFor(text, seconds) {
    message = text
    present("message")
    messageTimer.interval = Math.round(seconds * 1000)
    messageTimer.shownGeneration = generation
    messageTimer.restart()
  }

  function handle(line) {
    var data
    try { data = JSON.parse(line) } catch (e) { return }
    if (data.event === "disconnected" || data.event === "stopping") {
      sessionState = "off"
      if (mode !== "message") hide()
      return
    }
    if (data.event !== "state") return
    var next = String(data.state || "idle")
    if (typeof data.level === "number") level = data.level
    else if (next === "recording") level = -120
    if (typeof data.elapsed === "number") elapsed = data.elapsed
    if (!enabled) { sessionState = next; return }
    if (next === "recording") {
      if (mode !== "recording") {
        meter.reset()
        fractions = meter.step(-120, 0)
        present("recording")
      }
    } else if (next === "transcribing" || next === "cancelling") {
      if (mode !== "processing") {
        processingStart = Date.now() / 1000
        present("processing")
      }
    } else if (next === "idle") {
      var wasActive = sessionState === "recording" || sessionState === "transcribing" || sessionState === "cancelling"
      if (wasActive) {
        var text = Model.message(data, deliveryMode)
        if (text === null && (sessionState === "recording" || sessionState === "cancelling")) text = { headline: "Cancelled", detail: null, isError: false }
        if (text) showMessageFor(text, 2.5)
        else hide()
      } else if (mode !== "message") hide()
    }
    sessionState = next
  }

  function control(action) {
    if (!app || app.helper === "") return
    Platform.run([app.helper, action], function(out, code) {})
  }

  Connections {
    target: PillFeed
    function onLine(text) { pill.handle(text) }
  }

  Timer {
    id: messageTimer
    property int shownGeneration: 0
    onTriggered: if (pill.generation === shownGeneration) pill.hide()
  }

  FrameAnimation {
    running: pill.mode === "recording" || pill.mode === "processing"
    onTriggered: {
      if (pill.mode === "recording") pill.fractions = pill.meter.step(pill.level, frameTime)
      else pill.processingTime = Date.now() / 1000 - pill.processingStart
    }
  }

  // Delivery mode, so the settled message says pasted, typed or saved.
  property var configWatch: null
  Component.onCompleted: {
    var home = Platform.env("HOME")
    var path = Host.pillConfig !== "" ? Host.pillConfig : home + "/.local/share/mouthtype/speech-candidate/linux.json"
    configWatch = Platform.watch(path, function(text) {
      try {
        var value = JSON.parse(text || "{}")
        pill.deliveryMode = value && value.delivery && value.delivery.mode ? String(value.delivery.mode) : "recover"
      } catch (e) { pill.deliveryMode = "recover" }
    })
  }
  Component.onDestruction: if (configWatch) configWatch.destroy()

  // Only the controls take clicks and only while recording; the rest of the surface lets them through to the app below.
  readonly property rect controlsRect: {
    var skinItem = skin === "hifi" ? hifiLoader.item : classicLoader.item
    if (!showControls || !skinItem) return Qt.rect(0, 0, 1, 1)
    if (skin === "hifi") {
      var r = skinItem.controlsRect
      return Qt.rect(stage.x + hifiLoader.x + r.x, stage.y + hifiLoader.y + r.y, r.width, r.height)
    }
    return Qt.rect(classicLoader.x + skinItem.capsule.x, classicLoader.y + skinItem.capsule.y, skinItem.capsule.width, skinItem.capsule.height)
  }
  onControlsRectChanged: Host.setInputRegion(pill, Math.floor(controlsRect.x), Math.floor(controlsRect.y), Math.ceil(controlsRect.width), Math.ceil(controlsRect.height))

  Item {
    id: stage
    anchors.fill: parent
    opacity: pill.showing ? 1 : 0
    transform: Translate { y: pill.showing ? 0 : 5 }
    Behavior on opacity { NumberAnimation { duration: pill.showing ? 260 : 160; easing.type: pill.showing ? Easing.OutCubic : Easing.InCubic } }

    Loader {
      id: classicLoader
      x: (parent.width - width) / 2
      y: parent.height - height - 8
      active: pill.skin === "classic"
      sourceComponent: ClassicPill {
        mode: pill.mode
        message: pill.message
        fractions: pill.fractions
        processingTime: pill.processingTime
        showControls: pill.showControls
        devicePixelRatio: pill.screen ? pill.screen.devicePixelRatio : 1
        pillFont: pill.app ? pill.app.pillFont : ""
        cardStyle: pill.pillPrefs.card === "minimal" ? "minimal" : "classic"
        dark: Theme.dark
        onCancelRequested: pill.control("cancel")
        onStopRequested: pill.control("stop")
      }
    }
    Loader {
      id: hifiLoader
      x: (parent.width - width) / 2
      y: parent.height - height - 8
      active: pill.skin === "hifi"
      sourceComponent: HifiPill {
        mode: pill.mode
        message: pill.message
        fractions: pill.fractions
        processingTime: pill.processingTime
        elapsed: pill.elapsed
        showControls: pill.showControls
        s: pill.hifiScale
        onCancelRequested: pill.control("cancel")
        onStopRequested: pill.control("stop")
      }
    }
  }

  // Test hook for --pill-screenshot: the first time the pill is up, let it settle, grab it, report.
  Timer {
    id: grabTimer
    interval: Host.settleMs + 300
    running: Host.pillScreenshotPath !== "" && pill.mode === "recording"
    onTriggered: stage.grabToImage(function(result) {
      if (result && result.saveToFile(Host.pillScreenshotPath)) Host.loaded()
      else Host.failed("could not save " + Host.pillScreenshotPath)
    })
  }
}
