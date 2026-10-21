import QtQuick

// Like QtQuick Controls, user input assigns `checked` (which replaces a binding on it); listen to `toggled` to mirror it.
// 42 by 24 switch (36 by 20 compact). The track is the accent when on and `track` when off; the knob is white. Space and
// Return toggle it when it has focus, and the focus ring uses Theme.focus.
Item {
  id: root

  property bool checked: false
  property bool compact: false
  property string text: ""
  signal toggled()

  implicitWidth: compact ? 36 : 42
  implicitHeight: compact ? 20 : 24
  width: implicitWidth
  height: implicitHeight
  opacity: enabled ? 1 : 0.45
  activeFocusOnTab: true

  function toggle() {
    checked = !checked
    toggled()
  }

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: root.checked ? Theme.accent : Theme.track
    Behavior on color { ColorAnimation { duration: 120 } }
  }

  Rectangle {
    width: root.height - 4
    height: width
    radius: width / 2
    y: 2
    x: root.checked ? root.width - width - 2 : 2
    color: "#FFFFFF"
    Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: height / 2
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus(); root.toggle() }
  }

  Keys.onSpacePressed: toggle()
  Keys.onReturnPressed: toggle()

  Accessible.role: Accessible.CheckBox
  Accessible.name: text
  Accessible.checked: checked
  Accessible.onPressAction: toggle()
}
