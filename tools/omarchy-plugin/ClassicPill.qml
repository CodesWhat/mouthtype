import QtQuick
import "design"
import "PillModel.js" as Model

// The Classic skin: a dark capsule with ten bars, two discs while recording, and the settled message as a PillCard. Pure
// QtQuick, so the render sheet can draw it without Quickshell. Service.qml feeds it the controller state and turns the
// two signals into control calls.
Item {
  id: classic

  // Controller state, as Service.qml holds it: "recording", "processing" or "message".
  property string mode: "recording"
  property var message: null
  property var fractions: []
  property real processingTime: 0
  property bool showControls: false
  property real devicePixelRatio: 1
  // The user's pill font; empty is the bundled Default.
  property string pillFont: ""
  property string cardStyle: "classic"
  property bool dark: Theme.dark
  signal cancelRequested()
  signal stopRequested()

  readonly property alias capsule: capsule
  readonly property real scale: devicePixelRatio
  function snapEven(v) { return 2 * Math.round(v * scale / 2) / scale }
  readonly property real barWidth: Math.max(2 / scale, snapEven(2.25))
  readonly property real barPitch: Math.max(2 / scale, snapEven(4.25))
  readonly property real maxBar: Math.max(barWidth, snapEven(14.25))
  readonly property real barsSpan: 9 * barPitch + barWidth
  readonly property real holdWidth: 2 * Math.ceil((barsSpan + 18) * scale / 2) / scale
  readonly property real lockedWidth: 2 * Math.ceil((2 * (5 + 18 + 10) + barsSpan) * scale / 2) / scale
  readonly property bool isMessage: mode === "message"

  implicitWidth: Math.max(isMessage ? card.width : capsule.width, 1)
  implicitHeight: Math.max(isMessage ? card.height : capsule.height, 28)

  Rectangle {
    id: capsule
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    width: classic.mode === "recording" ? classic.lockedWidth : classic.holdWidth
    height: 28
    radius: 14
    opacity: classic.isMessage ? 0 : 1
    color: Qt.rgba(0x1A / 255, 0x1A / 255, 0x1A / 255, 0.96)
    border.color: "#4D4A42"
    border.width: 1
    Behavior on width { NumberAnimation { duration: 165; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 120 } }

    // Bars
    Item {
      anchors.centerIn: parent
      width: classic.barsSpan
      height: classic.maxBar
      Repeater {
        model: Model.BAR_COUNT
        Rectangle {
          required property int index
          readonly property real fractionValue: classic.mode === "processing"
            ? Model.processingFractions(classic.processingTime)[index]
            : (classic.fractions.length > index ? classic.fractions[index] : 0)
          width: classic.barWidth
          height: classic.snapEven(classic.barWidth + (classic.maxBar - classic.barWidth) * Math.min(1, Math.max(0, fractionValue)))
          radius: width / 2
          color: "#FFFFEB"
          x: index * classic.barPitch
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    // Controls, cancel on the left and stop on the right.
    Item {
      id: discs
      anchors.fill: parent
      opacity: classic.showControls ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
      Rectangle {
        id: cancelDisc
        x: 5; anchors.verticalCenter: parent.verticalCenter
        width: 18; height: 18; radius: 9
        color: cancelArea.pressed ? "#5C5C5A" : cancelArea.containsMouse ? "#858582" : "#71716E"
        scale: cancelArea.pressed ? 0.92 : 1
        Canvas {
          anchors.fill: parent
          onPaint: {
            var ctx = getContext("2d"); ctx.reset(); ctx.strokeStyle = "#FCFCFB"; ctx.lineWidth = 1.5; ctx.lineCap = "round"
            var c = width / 2, h = 3.1
            ctx.beginPath(); ctx.moveTo(c - h, c - h); ctx.lineTo(c + h, c + h); ctx.moveTo(c - h, c + h); ctx.lineTo(c + h, c - h); ctx.stroke()
          }
        }
        MouseArea { id: cancelArea; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; enabled: classic.showControls; cursorShape: Qt.PointingHandCursor; onClicked: classic.cancelRequested() }
      }
      Rectangle {
        id: stopDisc
        anchors.right: parent.right; anchors.rightMargin: 5; anchors.verticalCenter: parent.verticalCenter
        width: 18; height: 18; radius: 9
        color: stopArea.pressed ? "#D2D2CF" : stopArea.containsMouse ? "#EDEDEB" : "#FCFCFB"
        scale: stopArea.pressed ? 0.92 : 1
        Rectangle { anchors.centerIn: parent; width: 7; height: 7; radius: 1.5; color: "#1A1A1A" }
        MouseArea { id: stopArea; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; enabled: classic.showControls; cursorShape: Qt.PointingHandCursor; onClicked: classic.stopRequested() }
      }
    }
  }

  // The settled message.
  PillCard {
    id: card
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    opacity: classic.isMessage ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 120 } }
    style: classic.cardStyle
    dark: classic.dark
    fontFamily: classic.pillFont
    headline: classic.message ? classic.message.headline : ""
    detail: classic.message && classic.message.detail ? classic.message.detail : ""
    isError: !!(classic.message && classic.message.isError)
  }
}
