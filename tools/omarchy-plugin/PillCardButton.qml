import QtQuick
import "design"
import "CardPalette.js" as Cards

// A button on the pill card: 26 high, at least 64 wide, rounded like the squircle cards (a capsule on Classic). The
// primary button is lime on Minimal and lightens on hover and press so its dark label keeps contrast.
Item {
  id: root

  property var palette: null
  property string text: ""
  property bool primary: false
  property string previewState: ""
  signal activated()

  readonly property bool hovered: previewState === "hover" || mouse.containsMouse
  readonly property bool down: previewState === "press" || mouse.pressed

  implicitWidth: Math.max(64, Math.ceil(label.implicitWidth) + 28)
  implicitHeight: 26
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: root.palette && root.palette.style === "classic" ? height / 2 : 8
    color: !root.palette ? "transparent"
      : root.primary ? Cards.primaryFill(root.palette, root.hovered, root.down)
      : Cards.tintFill(root.palette, root.hovered, root.down)
    border.width: root.primary && root.palette && root.palette.primaryEdge ? 1 : 0
    border.color: root.palette && root.palette.primaryEdge ? root.palette.primaryEdge : "transparent"
  }
  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: !root.palette ? "transparent" : root.primary ? root.palette.primaryText : root.palette.secondaryText
    font: Type.sans(12, "semibold")
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: activated()
}
