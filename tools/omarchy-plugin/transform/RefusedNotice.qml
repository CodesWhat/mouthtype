import QtQuick
import "../design"

// The amber notice after Accept was refused. Orange is allowed for warnings only, so this is where it appears.
Rectangle {
  id: root

  property string title: ""
  property string detail: ""

  implicitHeight: column.implicitHeight + 20
  height: implicitHeight
  radius: 8
  color: Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.16)
  border.width: 1
  border.color: Qt.rgba(Theme.orange.r, Theme.orange.g, Theme.orange.b, 0.55)

  Column {
    id: column
    x: 12
    y: 10
    width: parent.width - 24
    spacing: 2

    Text {
      width: parent.width
      text: root.title
      wrapMode: Text.Wrap
      color: Theme.ink
      font: Type.sans(Type.detail, "medium")
    }
    Text {
      width: parent.width
      visible: root.detail !== ""
      text: root.detail
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
  }

  Accessible.role: Accessible.AlertMessage
  Accessible.name: title + " " + detail
}
