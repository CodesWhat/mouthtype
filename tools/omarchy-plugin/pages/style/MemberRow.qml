import QtQuick
import "../../design"
import "../../parts"

// One app in a list: a letter tile, the name with its BUILT IN or ADDED BY YOU tag, a tone popup, a cleanup popup and remove.
// Sits directly in a DesignCard. The name column wraps instead of cutting when the popups take the width.
Item {
  id: root

  property string name: ""
  property string tag: ""
  property string detail: ""
  property var toneModel: []
  property int toneValue: 0
  property var cleanupModel: []
  property int cleanupValue: 0
  property string removeLabel: "Remove"
  property bool cardFirst: true
  property bool cardLast: true
  signal toneChosen(int index)
  signal cleanupChosen(int index)
  signal removed()

  readonly property real controlsWidth: tonePopup.width + cleanupPopup.width + removeButton.width + 16

  width: parent ? parent.width : 520
  implicitHeight: Math.max(52, labels.height + 18)
  height: implicitHeight

  Rectangle {
    visible: !root.cardFirst
    anchors.left: parent.left
    anchors.right: parent.right
    height: 1
    color: Theme.hair2
  }

  Rectangle {
    id: tile
    x: 14
    anchors.verticalCenter: parent.verticalCenter
    width: 24
    height: 24
    radius: 6
    color: Theme.sel
    Text {
      anchors.centerIn: parent
      text: root.name.length ? root.name.charAt(0).toUpperCase() : ""
      color: Theme.ink
      font: Type.sans(Type.detail, "semibold")
    }
  }

  Column {
    id: labels
    x: 50
    anchors.verticalCenter: parent.verticalCenter
    width: Math.max(80, parent.width - 50 - root.controlsWidth - 20)
    spacing: 1

    Text {
      width: parent.width
      text: root.name
      wrapMode: Text.Wrap
      color: Theme.ink
      font: Type.sans(Type.body, "medium")
    }
    Text {
      visible: root.tag !== ""
      width: parent.width
      text: root.tag
      wrapMode: Text.Wrap
      color: Theme.ink3
      font: Type.eyebrow
    }
    Text {
      visible: root.detail !== ""
      width: parent.width
      text: root.detail
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
  }

  Row {
    id: controls
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    spacing: 8

    StatePopup {
      id: tonePopup
      model: root.toneModel
      value: root.toneValue
      text: "Tone for " + root.name
      onActivated: function(index) { root.toneChosen(index) }
    }
    StatePopup {
      id: cleanupPopup
      model: root.cleanupModel
      value: root.cleanupValue
      text: "Cleanup for " + root.name
      onActivated: function(index) { root.cleanupChosen(index) }
    }
    Item {
      id: removeButton
      width: 28
      height: 28
      activeFocusOnTab: true
      Icon { anchors.centerIn: parent; name: "close"; size: 16; color: Theme.ink3 }
      Rectangle {
        anchors.fill: parent
        radius: 7
        color: "transparent"
        border.width: 2
        border.color: Theme.focus
        visible: removeButton.activeFocus
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.removed()
      }
      Keys.onSpacePressed: root.removed()
      Keys.onReturnPressed: root.removed()
      Accessible.role: Accessible.Button
      Accessible.name: root.removeLabel
      Accessible.onPressAction: root.removed()
    }
  }
}
