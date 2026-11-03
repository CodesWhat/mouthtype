import QtQuick
import "../design"
import ".."

// Every pill state and the delivery cards on one sheet, for the offscreen render. `dark` pins Theme and the desktop
// behind the pill. Classic is the shipped default; Minimal shows the lime-palette card, which follows `dark`.
Rectangle {
  id: root

  property bool dark: false

  width: 760
  height: 980
  color: dark ? "#2A2A2E" : "#E4E4E8"

  Binding { target: Theme; property: "forceDark"; value: root.dark }

  readonly property var bars: [0.10, 0.25, 0.50, 0.80, 1.0, 0.90, 0.60, 0.40, 0.20, 0.10]
  readonly property var delivered: ({ headline: "Pasted", detail: "Check the field", isError: false })
  readonly property var saved: ({ headline: "Saved", detail: null, isError: false })
  readonly property var failed: ({ headline: "Couldn't transcribe", detail: "Audio saved for retry", isError: true })
  readonly property var cancelled: ({ headline: "Cancelled", detail: null, isError: false })

  component Tile: Item {
    id: tile
    property string caption: ""
    default property alias content: slot.data
    width: 340
    height: 66
    Text {
      x: 0; y: 0
      width: parent.width
      text: tile.caption
      color: root.dark ? "#C8C8CC" : "#3A3A3C"
      font: Type.eyebrow
    }
    Item { id: slot; x: 0; y: 18; width: parent.width; height: 48 }
  }

  component Pill: ClassicPill {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 4
  }

  Text {
    x: 28; y: 18
    text: "Classic pill"
    color: root.dark ? "#F2F2F2" : "#1D1D1F"
    font: Type.serif(22)
  }
  Column {
    x: 28; y: 56
    spacing: 6
    Tile { caption: "Idle (pill hidden)" }
    Tile { caption: "Recording"; Pill { mode: "recording"; showControls: true; fractions: root.bars } }
    Tile { caption: "Processing"; Pill { mode: "processing"; processingTime: 0.35 } }
    Tile { caption: "Delivered"; Pill { mode: "message"; message: root.delivered } }
    Tile { caption: "Delivered, no detail"; Pill { mode: "message"; message: root.saved } }
    Tile { caption: "Failed"; Pill { mode: "message"; message: root.failed } }
    Tile { caption: "Cancelled"; Pill { mode: "message"; message: root.cancelled } }
  }

  Text {
    x: 392; y: 18
    text: "Minimal card"
    color: root.dark ? "#F2F2F2" : "#1D1D1F"
    font: Type.serif(22)
  }
  Column {
    x: 392; y: 56
    spacing: 8
    Tile { caption: "Delivered"; Pill { mode: "message"; message: root.delivered; cardStyle: "minimal" } }
    Tile { caption: "Failed"; Pill { mode: "message"; message: root.failed; cardStyle: "minimal" } }
    Tile { caption: "Cancelled"; Pill { mode: "message"; message: root.cancelled; cardStyle: "minimal" } }
    Tile { caption: "User font (Mono preset)"; Pill { mode: "message"; message: root.delivered; cardStyle: "minimal"; pillFont: "DejaVu Sans Mono" } }
  }

  Text {
    x: 28; y: 640
    text: "Cards with actions"
    color: root.dark ? "#F2F2F2" : "#1D1D1F"
    font: Type.serif(22)
  }
  Grid {
    x: 28; y: 680
    columns: 3
    spacing: 16
    component Card: Column {
      property string caption: ""
      property string style: "classic"
      property string state: ""
      spacing: 6
      Text { text: parent.caption; color: root.dark ? "#C8C8CC" : "#3A3A3C"; font: Type.eyebrow }
      PillCard {
        style: parent.style
        headline: "Paste failed"
        detail: "Your text is safe"
        isError: true
        primaryText: "Copy"
        secondaryText: "Not now"
        previewState: parent.state
      }
    }
    Card { caption: "Classic, rest"; style: "classic" }
    Card { caption: "Minimal, rest"; style: "minimal" }
    Card { caption: "Minimal, hover"; style: "minimal"; state: "hover" }
    Card { caption: "Classic, press"; style: "classic"; state: "press" }
    Card { caption: "Minimal, press"; style: "minimal"; state: "press" }
  }
}
