import QtQuick
import "../design"

// A row in the Settings modal's own nav: 34 high, sel tint when selected, no icon (the V1 set has no General, Linux or Health
// glyphs). There is no lime bar.
Item {
  id: root

  property string title: ""
  property bool selected: false
  signal activated()

  implicitWidth: 160
  implicitHeight: 34
  width: parent ? parent.width : implicitWidth
  height: implicitHeight
  activeFocusOnTab: true

  Rectangle {
    anchors.fill: parent
    radius: Theme.navRadius
    color: Theme.sel
    visible: root.selected || mouse.containsMouse
    opacity: root.selected ? 1 : 0.6
  }
  Rectangle {
    anchors.fill: parent
    radius: Theme.navRadius
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }
  Text {
    x: 12
    width: parent.width - 24
    anchors.verticalCenter: parent.verticalCenter
    text: root.title
    wrapMode: Text.Wrap
    color: Theme.ink
    font: Type.sans(Type.body, "medium")
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus(); root.activated() }
  }

  Keys.onSpacePressed: activated()
  Keys.onReturnPressed: activated()

  Accessible.role: Accessible.Button
  Accessible.name: title
  Accessible.selected: selected
  Accessible.onPressAction: activated()
}
