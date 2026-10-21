import QtQuick
import QtQuick.Controls

// 28 high select, radius 7. `model` is a list of strings; `currentIndex` is the selection. The menu is 28 high per row with
// a check on the current one.
Item {
  id: root

  property var model: []
  property int currentIndex: 0
  property string text: ""
  readonly property string currentText: currentIndex >= 0 && currentIndex < model.length ? model[currentIndex] : ""
  signal activated(int index)

  implicitWidth: face.wantedWidth
  implicitHeight: Theme.controlHeight
  width: implicitWidth
  height: implicitHeight
  activeFocusOnTab: true
  opacity: enabled ? 1 : 0.45

  Rectangle {
    id: face
    readonly property real wantedWidth: label.implicitWidth + 10 + 16 + 18
    anchors.fill: parent
    radius: Theme.controlRadius
    color: Theme.surface
    border.width: 1
    border.color: Theme.hair
  }
  Text {
    id: label
    x: 10
    anchors.verticalCenter: parent.verticalCenter
    text: root.currentText
    color: Theme.ink
    font: Type.sans(Type.detail)
  }
  Icon {
    anchors.right: parent.right
    anchors.rightMargin: 8
    anchors.verticalCenter: parent.verticalCenter
    name: "chevron-down"
    size: 16
    color: Theme.ink2
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
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus(); menu.opened ? menu.close() : menu.open() }
  }

  Keys.onSpacePressed: menu.open()
  Keys.onReturnPressed: menu.open()
  Keys.onUpPressed: if (currentIndex > 0) { currentIndex--; activated(currentIndex) }
  Keys.onDownPressed: if (currentIndex < model.length - 1) { currentIndex++; activated(currentIndex) }

  Popup {
    id: menu
    focus: true
    y: root.height + 4
    padding: 4
    width: Math.max(root.width, list.implicitWidth + 8)
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
      radius: 8
      color: Theme.surface
      border.width: 1
      border.color: Theme.hair
    }

    contentItem: Column {
      id: list
      readonly property real implicitWidth: {
        var w = 0
        for (var i = 0; i < children.length; i++) w = Math.max(w, children[i].implicitWidth || 0)
        return w
      }
      Repeater {
        model: root.model
        delegate: Item {
          id: option
          required property var modelData
          required property int index
          readonly property real implicitWidth: optionLabel.implicitWidth + 36
          width: list.width
          height: 28
          Rectangle {
            anchors.fill: parent
            radius: 5
            color: Theme.sel
            visible: optionMouse.containsMouse
          }
          Icon {
            x: 6
            anchors.verticalCenter: parent.verticalCenter
            name: "check"
            size: 16
            color: Theme.ink
            visible: option.index === root.currentIndex
          }
          Text {
            id: optionLabel
            x: 28
            anchors.verticalCenter: parent.verticalCenter
            text: option.modelData
            color: Theme.ink
            font: Type.sans(Type.detail)
          }
          MouseArea {
            id: optionMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
              root.currentIndex = option.index
              root.activated(option.index)
              menu.close()
            }
          }
        }
      }
    }
  }

  Accessible.role: Accessible.ComboBox
  Accessible.name: text
}
