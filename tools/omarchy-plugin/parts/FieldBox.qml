import QtQuick
import QtQuick.Controls
import "../design"

// A single-line text field in the design language: surface fill, hair border, the focus ring when active.
TextField {
  id: root

  property bool ring: false
  // The hint shown while the field is empty. Drawn here instead of with placeholderText, whose label elides.
  property string hint: ""

  implicitHeight: Theme.controlHeight + 4
  leftPadding: 10
  rightPadding: 10
  color: Theme.ink
  selectionColor: Theme.accent
  selectedTextColor: Theme.onAccent
  font: Type.sans(Type.detail)
  verticalAlignment: TextInput.AlignVCenter

  background: Rectangle {
    radius: Theme.controlRadius
    color: Theme.surface
    border.width: root.activeFocus || root.ring ? 2 : 1
    border.color: root.activeFocus || root.ring ? Theme.focus : Theme.hair
  }

  Text {
    visible: root.text === "" && !root.preeditText
    x: root.leftPadding
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width - root.leftPadding - root.rightPadding
    text: root.hint
    wrapMode: Text.NoWrap
    clip: true
    color: Theme.ink3
    font: root.font
  }
}
