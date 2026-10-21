import QtQuick

// Shared body of DesignPrimaryButton and DesignSecondaryButton: 28 high, radius 7. Use those two, not this.
Item {
  id: root

  property string text: ""
  property bool primary: false
  signal activated()

  implicitWidth: label.implicitWidth + 20
  implicitHeight: Theme.controlHeight
  width: implicitWidth
  height: implicitHeight
  opacity: enabled ? 1 : 0.45
  activeFocusOnTab: true

  Rectangle {
    id: face
    anchors.fill: parent
    radius: Theme.controlRadius
    color: root.primary ? Theme.accent : Theme.surface
    border.width: root.primary ? 0 : 1
    border.color: Theme.hair
  }
  Rectangle {
    anchors.fill: parent
    radius: Theme.controlRadius
    color: Qt.rgba(0, 0, 0, 0.1)
    visible: mouse.pressed
  }
  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: Theme.controlRadius + 3
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }
  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: root.primary ? Theme.onAccent : Theme.ink
    font: Type.sans(Type.detail, "medium")
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus(); root.activated() }
  }

  Keys.onSpacePressed: activated()
  Keys.onReturnPressed: activated()

  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: activated()
}
