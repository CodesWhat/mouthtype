import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "design"
import "PillModel.js" as Model
import "Fonts.js" as Fonts

// The floating pill: a passive layer-shell overlay on the focused output, fed by the Linux client's text-free
// state stream. It never takes keyboard focus; only the cancel and stop controls are clickable, and only while
// recording.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string plugin: home + "/.config/omarchy/plugins/dstahl.mouthtype"
  readonly property string helper: plugin + "/control.py"
  readonly property string launcher: home + "/.local/bin/mouthtype-linux"
  readonly property string config: home + "/.local/share/mouthtype/speech-candidate/linux.json"

  property var prefs: ({})
  readonly property var pillPrefs: prefs && prefs.pill ? prefs.pill : ({})
  readonly property bool enabled: pillPrefs.enabled !== false
  readonly property string skin: pillPrefs.skin === "hifi" ? "hifi" : "classic"
  readonly property int hifiScale: pillPrefs.size === 2 ? 2 : 1
  readonly property string cardStyle: pillPrefs.card === "minimal" ? "minimal" : "classic"
  property string deliveryMode: "recover"

  // Controller state: hidden, recording, processing, message.
  property string mode: "hidden"
  property string sessionState: "off"
  property var snapshot: ({})
  property var message: null
  property real elapsed: 0
  property real level: -120
  property var fractions: []
  property real processingStart: 0
  property real processingTime: 0
  property int generation: 0
  property var activeScreen: null
  property bool connected: false
  property var meter: new Model.Meter()

  readonly property bool showing: mode !== "hidden"
  readonly property bool showControls: mode === "recording"

  function log(text) { console.log("mouthtype pill: " + text) }

  function present(nextMode) {
    generation += 1
    if (mode === "hidden") activeScreen = focusedScreen()
    mode = nextMode
  }

  // The output Hyprland has focused, matched by name as the bar does; the first screen otherwise.
  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
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
    var shown = generation
    messageTimer.interval = Math.round(seconds * 1000)
    messageTimer.shownGeneration = shown
    messageTimer.restart()
  }

  function handle(line) {
    var data
    try { data = JSON.parse(line) } catch (e) { return }
    if (data.event === "disconnected" || data.event === "stopping") {
      connected = false
      sessionState = "off"
      if (mode !== "message") hide()
      return
    }
    if (data.event !== "state") return
    connected = true
    var previous = snapshot
    snapshot = data
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
    if (controlProc.running) return
    controlProc.command = [root.helper, action]
    controlProc.running = true
  }

  Component.onCompleted: log("service loaded")

  Timer {
    id: messageTimer
    property int shownGeneration: 0
    onTriggered: if (root.generation === shownGeneration) root.hide()
  }

  FrameAnimation {
    running: root.mode === "recording" || root.mode === "processing"
    onTriggered: {
      if (root.mode === "recording") root.fractions = root.meter.step(root.level, frameTime)
      else root.processingTime = Date.now() / 1000 - root.processingStart
    }
  }

  // Preferences: skin, size, enabled flag and fonts, shared with the bar menu.
  FileView {
    id: prefsFile
    path: root.home + "/.config/mouthtype/omarchy-plugin.json"
    watchChanges: true
    onLoaded: root.readPrefs(text())
    onFileChanged: reload()
    onLoadFailed: root.prefs = ({})
  }
  function readPrefs(raw) {
    try { prefs = JSON.parse(raw || "{}") || ({}) } catch (e) { prefs = ({}) }
  }

  // Delivery mode, so the settled message says pasted, typed or saved.
  FileView {
    id: configFile
    path: root.config
    watchChanges: true
    onLoaded: root.readConfig(text())
    onFileChanged: reload()
  }
  function readConfig(raw) {
    try {
      var value = JSON.parse(raw || "{}")
      deliveryMode = value && value.delivery && value.delivery.mode ? String(value.delivery.mode) : "recover"
    } catch (e) { deliveryMode = "recover" }
  }

  // One long-lived watcher; it reconnects itself while the service is absent.
  Process {
    id: watchProc
    command: ["setpriv", "--pdeathsig", "TERM", root.launcher, "--config", root.config, "watch", "--retry"]
    running: true
    stdout: SplitParser { onRead: function(data) { root.handle(data) } }
    onExited: restartTimer.restart()
  }
  Timer { id: restartTimer; interval: 3000; onTriggered: if (!watchProc.running) watchProc.running = true }

  Process {
    id: controlProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Floating windows owned by later slices load only once their file exists, so a build without them stays quiet.
  FileView {
    path: root.plugin + "/TransformWindow.qml"
    printErrors: false
    onLoaded: transformWindow.active = true
  }
  Loader {
    id: transformWindow
    active: false
    source: "file://" + root.plugin + "/TransformWindow.qml"
    onLoaded: if (item && item.shell !== undefined) item.shell = root.shell
  }

  PanelWindow {
    id: panel
    visible: root.showing && root.activeScreen !== null
    screen: root.activeScreen
    anchors.bottom: true
    margins.bottom: 12
    implicitWidth: root.skin === "hifi" ? 146 * root.hifiScale + 48 : 360 + 48
    implicitHeight: root.skin === "hifi" ? 32 * root.hifiScale + 24 : 100
    color: "transparent"
    WlrLayershell.namespace: "mouthtype-pill"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: root.showControls ? controlsRegion : emptyRegion

    Region { id: emptyRegion }
    Region {
      id: controlsRegion
      item: root.skin === "hifi" ? hifiControls : classicControls
    }

    // Everything fades and rises a little on appear, drops on hide.
    Item {
      id: stage
      anchors.fill: parent
      opacity: root.showing ? 1 : 0
      transform: Translate { y: root.showing ? 0 : 5 }
      Behavior on opacity { NumberAnimation { duration: root.showing ? 260 : 160; easing.type: root.showing ? Easing.OutCubic : Easing.InCubic } }

      Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        active: root.skin === "classic"
        sourceComponent: classicSkin
      }
      Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        active: root.skin === "hifi"
        sourceComponent: hifiSkin
      }
    }

    // Invisible anchors for the input region; the skins position them over their drawn controls.
    Item { id: classicControls }
    Item { id: hifiControls }
  }

  // MARK: Classic skin — a dark capsule with ten bars, two discs when controls show, a delivery card for a message.
  Component {
    id: classicSkin
    ClassicPill {
      id: classic
      mode: root.mode
      message: root.message
      fractions: root.fractions
      processingTime: root.processingTime
      showControls: root.showControls
      devicePixelRatio: panel.screen ? panel.screen.devicePixelRatio : 1
      pillFont: Fonts.family(root.prefs, "pill", "")
      cardStyle: root.cardStyle
      dark: Theme.dark
      onCancelRequested: root.control("cancel")
      onStopRequested: root.control("stop")

      // Input region follows the drawn discs.
      Binding { target: classicControls; property: "x"; value: classic.capsule.mapToItem(panel.contentItem, 0, 0).x }
      Binding { target: classicControls; property: "y"; value: classic.capsule.mapToItem(panel.contentItem, 0, 0).y }
      Binding { target: classicControls; property: "width"; value: classic.capsule.width }
      Binding { target: classicControls; property: "height"; value: classic.capsule.height }
    }
  }

  // MARK: Hi-Fi skin — the Mac chassis and sprites, drawn as crisp pixel blocks.
  Component {
    id: hifiSkin
    Item {
      id: hifi
      readonly property int s: root.hifiScale
      readonly property string dir: root.plugin + "/assets/hifi/"
      property var layout: ({})
      readonly property var meterSegments: layout.meter ? layout.meter.segments : []
      readonly property var tiers: layout.meter ? layout.meter.rowTiers : []
      readonly property var colors: layout.colors || ({})
      readonly property bool isMessage: root.mode === "message"
      readonly property var lit: root.mode === "recording" ? Model.litSegments(root.fractions, Model.SEGMENT_ROWS) : []
      readonly property var run: root.mode === "processing" ? Model.processingColumns(root.processingTime) : [-1, -1]
      readonly property bool ledOn: root.mode === "recording" && Model.ledOn(root.elapsed, true)
      implicitWidth: 146 * s
      implicitHeight: 32 * s

      FileView { path: hifi.dir + "layout.json"; onLoaded: { try { hifi.layout = JSON.parse(text()) } catch (e) {} } }

      function tierColor(row) {
        var tier = tiers[row] || "normal"
        return tier === "peak" ? colors.segmentPeak : tier === "hot" ? colors.segmentHot : colors.segmentNormal
      }
      function sprite(name) { return layout.sprites ? layout.sprites[name] : null }

      Image { source: hifi.dir + "chassis.png"; width: 146 * hifi.s; height: 32 * hifi.s; smooth: false; fillMode: Image.Stretch }

      // VFD window cover during a message
      Rectangle {
        visible: hifi.isMessage && !!hifi.layout.window
        x: (hifi.layout.window ? hifi.layout.window.x : 0) * hifi.s; y: (hifi.layout.window ? hifi.layout.window.y : 0) * hifi.s
        width: (hifi.layout.window ? hifi.layout.window.w : 0) * hifi.s; height: (hifi.layout.window ? hifi.layout.window.h : 0) * hifi.s
        color: hifi.colors.windowBackground || "#080b0a"
      }

      // Meter cells
      Repeater {
        model: hifi.meterSegments.length * Model.SEGMENT_ROWS
        Rectangle {
          required property int index
          readonly property int column: Math.floor(index / Model.SEGMENT_ROWS)
          readonly property int row: index % Model.SEGMENT_ROWS
          readonly property var cell: hifi.meterSegments[column] ? hifi.meterSegments[column][row] : null
          visible: !hifi.isMessage && cell !== null && (
            root.mode === "recording" ? (hifi.lit[column] || 0) > row
            : root.mode === "processing" ? (row === 2 && column >= hifi.run[0] && column <= hifi.run[1]) : false)
          x: (cell ? cell.x : 0) * hifi.s; y: (cell ? cell.y : 0) * hifi.s
          width: (cell ? cell.w : 0) * hifi.s; height: (cell ? cell.h : 0) * hifi.s
          color: hifi.tierColor(row)
        }
      }

      // Lamps and buttons
      Image { readonly property var spec: hifi.sprite("led_glow"); visible: hifi.ledOn && !!spec; source: hifi.dir + "led_glow.png"; smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }
      Image { readonly property var spec: hifi.sprite("led_on"); visible: !!spec; source: hifi.dir + (hifi.ledOn ? "led_on.png" : "led_off.png"); smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }
      Image { readonly property var spec: hifi.sprite("talk_up"); visible: !!spec; source: hifi.dir + "talk_up.png"; smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }
      Image { readonly property var spec: hifi.sprite("padlock"); visible: root.mode === "recording" && !!spec; source: hifi.dir + "padlock.png"; smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }

      Image {
        id: cancelCap
        readonly property var spec: hifi.sprite("cancel")
        visible: !!spec
        source: hifi.dir + (root.showControls && !cancelCapArea.pressed ? "cancel_lit.png" : "cancel.png")
        smooth: false
        x: (spec ? spec.x : 0) * hifi.s; y: ((spec ? spec.y : 0) + (cancelCapArea.pressed ? 1 : 0)) * hifi.s
        width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s
        MouseArea { id: cancelCapArea; anchors.fill: parent; anchors.margins: -4; enabled: root.showControls; cursorShape: Qt.PointingHandCursor; onClicked: root.control("cancel") }
      }
      Image {
        id: stopCap
        readonly property var spec: hifi.sprite("stop")
        visible: !!spec
        source: hifi.dir + (root.showControls && !stopCapArea.pressed ? "stop_lit.png" : "stop.png")
        smooth: false
        x: (spec ? spec.x : 0) * hifi.s; y: ((spec ? spec.y : 0) + (stopCapArea.pressed ? 1 : 0)) * hifi.s
        width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s
        MouseArea { id: stopCapArea; anchors.fill: parent; anchors.margins: -4; enabled: root.showControls; cursorShape: Qt.PointingHandCursor; onClicked: root.control("stop") }
      }

      // Timer readout in the 3x5 face, and messages in the 5x7 face.
      BitmapText {
        visible: root.mode === "recording" && !!hifi.layout.text
        slot: hifi.layout.text ? hifi.layout.text.timerLocked : null
        fontSpec: hifi.layout.fonts && hifi.layout.text ? hifi.layout.fonts[hifi.layout.text.timerLocked.font] : null
        atlas: hifi.dir + "font-3.png"
        text: Model.timerText(root.elapsed)
        tint: hifi.colors.text || "#ffb02e"
        artScale: hifi.s
      }
      BitmapText {
        visible: hifi.isMessage && !!hifi.layout.text
        slot: hifi.layout.text ? hifi.layout.text.message : null
        fontSpec: hifi.layout.fonts && hifi.layout.text ? hifi.layout.fonts[hifi.layout.text.message.font] : null
        atlas: hifi.dir + "font-5.png"
        text: root.message ? (root.message.detail ? root.message.headline + " - " + root.message.detail : root.message.headline) : ""
        tint: root.message && root.message.isError ? (hifi.colors.error || "#ff3b2e") : (hifi.colors.text || "#ffb02e")
        artScale: hifi.s
        marquee: true
      }

      Binding { target: hifiControls; property: "x"; value: hifi.mapToItem(panel.contentItem, (cancelCap.spec ? cancelCap.spec.x : 0) * hifi.s - 4, 0).x }
      Binding { target: hifiControls; property: "y"; value: hifi.mapToItem(panel.contentItem, 0, 0).y }
      Binding { target: hifiControls; property: "width"; value: ((stopCap.spec ? stopCap.spec.x + stopCap.spec.w : 146) - (cancelCap.spec ? cancelCap.spec.x : 0)) * hifi.s + 8 }
      Binding { target: hifiControls; property: "height"; value: 32 * hifi.s }
    }
  }
}
