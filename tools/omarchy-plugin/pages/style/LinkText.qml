import QtQuick
import "../../design"

// A quiet underlined action in running text. Keyboard: Space or Return when focused.
Text {
  id: root

  signal activated()

  color: enabled ? Theme.ink : Theme.ink3
  font: { var f = Type.sans(Type.detail); f.underline = true; return f }
  activeFocusOnTab: true

  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: 4
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }
  MouseArea {
    anchors.fill: parent
    anchors.margins: -4
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus(); root.activated() }
  }
  Keys.onSpacePressed: activated()
  Keys.onReturnPressed: activated()

  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: activated()
}
