import QtQuick
import MouthtypePlatform
import "../omarchy-plugin"
import "../omarchy-plugin/PillModel.js" as Model

// The Hi-Fi skin for the Qt host: the Mac chassis and sprites drawn as crisp pixel blocks. The same drawing as the Hi-Fi
// component inside Service.qml (the Omarchy pill), fed by PillWindow properties instead of Service's, and reading layout.json
// through Platform instead of Quickshell's FileView.
Item {
  id: hifi

  property string mode: "hidden"
  property var message: null
  property var fractions: []
  property real processingTime: 0
  property real elapsed: 0
  property bool showControls: false
  property int s: 1

  signal cancelRequested()
  signal stopRequested()

  readonly property url dirUrl: Qt.resolvedUrl("../omarchy-plugin/assets/hifi/")
  readonly property string dir: String(dirUrl)
  property var layout: ({})
  readonly property var meterSegments: layout.meter ? layout.meter.segments : []
  readonly property var tiers: layout.meter ? layout.meter.rowTiers : []
  readonly property var colors: layout.colors || ({})
  readonly property bool isMessage: mode === "message"
  readonly property var lit: mode === "recording" ? Model.litSegments(fractions, Model.SEGMENT_ROWS) : []
  readonly property var run: mode === "processing" ? Model.processingColumns(processingTime) : [-1, -1]
  readonly property bool ledOn: mode === "recording" && Model.ledOn(elapsed, true)
  // Where the two clickable caps sit, in this item's coordinates.
  readonly property rect controlsRect: Qt.rect((cancelCap.spec ? cancelCap.spec.x : 0) * s - 4, 0,
    ((stopCap.spec ? stopCap.spec.x + stopCap.spec.w : 146) - (cancelCap.spec ? cancelCap.spec.x : 0)) * s + 8, 32 * s)
  implicitWidth: 146 * s
  implicitHeight: 32 * s

  Component.onCompleted: {
    try { layout = JSON.parse(Platform.readFile(dir.replace(/^file:\/\//, "") + "layout.json") || "{}") } catch (e) {}
  }

  function tierColor(row) {
    var tier = tiers[row] || "normal"
    return tier === "peak" ? colors.segmentPeak : tier === "hot" ? colors.segmentHot : colors.segmentNormal
  }
  function sprite(name) { return layout.sprites ? layout.sprites[name] : null }

  Image { source: hifi.dir + "chassis.png"; width: 146 * hifi.s; height: 32 * hifi.s; smooth: false; fillMode: Image.Stretch }

  Rectangle {
    visible: hifi.isMessage && !!hifi.layout.window
    x: (hifi.layout.window ? hifi.layout.window.x : 0) * hifi.s; y: (hifi.layout.window ? hifi.layout.window.y : 0) * hifi.s
    width: (hifi.layout.window ? hifi.layout.window.w : 0) * hifi.s; height: (hifi.layout.window ? hifi.layout.window.h : 0) * hifi.s
    color: hifi.colors.windowBackground || "#080b0a"
  }

  Repeater {
    model: hifi.meterSegments.length * Model.SEGMENT_ROWS
    Rectangle {
      required property int index
      readonly property int column: Math.floor(index / Model.SEGMENT_ROWS)
      readonly property int row: index % Model.SEGMENT_ROWS
      readonly property var cell: hifi.meterSegments[column] ? hifi.meterSegments[column][row] : null
      visible: !hifi.isMessage && cell !== null && (
        hifi.mode === "recording" ? (hifi.lit[column] || 0) > row
        : hifi.mode === "processing" ? (row === 2 && column >= hifi.run[0] && column <= hifi.run[1]) : false)
      x: (cell ? cell.x : 0) * hifi.s; y: (cell ? cell.y : 0) * hifi.s
      width: (cell ? cell.w : 0) * hifi.s; height: (cell ? cell.h : 0) * hifi.s
      color: hifi.tierColor(row)
    }
  }

  Image { readonly property var spec: hifi.sprite("led_glow"); visible: hifi.ledOn && !!spec; source: hifi.dir + "led_glow.png"; smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }
  Image { readonly property var spec: hifi.sprite("led_on"); visible: !!spec; source: hifi.dir + (hifi.ledOn ? "led_on.png" : "led_off.png"); smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }
  Image { readonly property var spec: hifi.sprite("talk_up"); visible: !!spec; source: hifi.dir + "talk_up.png"; smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }
  Image { readonly property var spec: hifi.sprite("padlock"); visible: hifi.mode === "recording" && !!spec; source: hifi.dir + "padlock.png"; smooth: false; x: (spec ? spec.x : 0) * hifi.s; y: (spec ? spec.y : 0) * hifi.s; width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s }

  Image {
    id: cancelCap
    readonly property var spec: hifi.sprite("cancel")
    visible: !!spec
    source: hifi.dir + (hifi.showControls && !cancelCapArea.pressed ? "cancel_lit.png" : "cancel.png")
    smooth: false
    x: (spec ? spec.x : 0) * hifi.s; y: ((spec ? spec.y : 0) + (cancelCapArea.pressed ? 1 : 0)) * hifi.s
    width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s
    MouseArea { id: cancelCapArea; anchors.fill: parent; anchors.margins: -4; enabled: hifi.showControls; cursorShape: Qt.PointingHandCursor; onClicked: hifi.cancelRequested() }
  }
  Image {
    id: stopCap
    readonly property var spec: hifi.sprite("stop")
    visible: !!spec
    source: hifi.dir + (hifi.showControls && !stopCapArea.pressed ? "stop_lit.png" : "stop.png")
    smooth: false
    x: (spec ? spec.x : 0) * hifi.s; y: ((spec ? spec.y : 0) + (stopCapArea.pressed ? 1 : 0)) * hifi.s
    width: (spec ? spec.w : 0) * hifi.s; height: (spec ? spec.h : 0) * hifi.s
    MouseArea { id: stopCapArea; anchors.fill: parent; anchors.margins: -4; enabled: hifi.showControls; cursorShape: Qt.PointingHandCursor; onClicked: hifi.stopRequested() }
  }

  BitmapText {
    visible: hifi.mode === "recording" && !!hifi.layout.text
    slot: hifi.layout.text ? hifi.layout.text.timerLocked : null
    fontSpec: hifi.layout.fonts && hifi.layout.text ? hifi.layout.fonts[hifi.layout.text.timerLocked.font] : null
    atlas: hifi.dir + "font-3.png"
    text: Model.timerText(hifi.elapsed)
    tint: hifi.colors.text || "#ffb02e"
    artScale: hifi.s
  }
  BitmapText {
    visible: hifi.isMessage && !!hifi.layout.text
    slot: hifi.layout.text ? hifi.layout.text.message : null
    fontSpec: hifi.layout.fonts && hifi.layout.text ? hifi.layout.fonts[hifi.layout.text.message.font] : null
    atlas: hifi.dir + "font-5.png"
    text: hifi.message ? (hifi.message.detail ? hifi.message.headline + " - " + hifi.message.detail : hifi.message.headline) : ""
    tint: hifi.message && hifi.message.isError ? (hifi.colors.error || "#ff3b2e") : (hifi.colors.text || "#ffb02e")
    artScale: hifi.s
    marquee: true
  }
}
