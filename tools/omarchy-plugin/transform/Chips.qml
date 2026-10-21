import QtQuick
import "../design"

// The transform chip row. `chips` is Model.chips(session): { id, title, active, enabled, reason }. A disabled chip dims
// and ignores clicks; the reason is written under the row by the panel, never in a tooltip.
Flow {
  id: root

  property var chips: []
  signal chosen(string kind)

  spacing: 6

  Repeater {
    model: root.chips
    delegate: Rectangle {
      id: chip
      required property var modelData
      readonly property bool active: modelData.active === true
      readonly property bool usable: modelData.enabled === true

      height: 28
      width: label.implicitWidth + 24
      radius: 14
      antialiasing: true
      color: active ? Theme.accentSoft : Theme.surface
      border.width: 1
      border.color: active ? Theme.accent : Theme.hair
      opacity: usable || active ? 1 : 0.45

      Text {
        id: label
        anchors.centerIn: parent
        text: chip.modelData.title
        color: chip.active ? Theme.accentText : Theme.ink2
        font: Type.sans(12.5, "medium")
      }
      MouseArea {
        anchors.fill: parent
        enabled: chip.usable
        cursorShape: Qt.PointingHandCursor
        onClicked: root.chosen(chip.modelData.id)
      }
      Accessible.role: Accessible.Button
      Accessible.name: modelData.title
      Accessible.checked: active
      Accessible.onPressAction: if (usable) root.chosen(modelData.id)
    }
  }
}
