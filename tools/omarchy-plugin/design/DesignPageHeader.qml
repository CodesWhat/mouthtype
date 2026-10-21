import QtQuick

// The serif headline (28, or 24 in the Settings modal) and one summary line. Items declared inside go to the trailing edge.
Item {
  id: root

  property string title: ""
  property string summary: ""
  property real titleSize: Type.headline
  default property alias trailing: trailingRow.data

  implicitWidth: 320
  implicitHeight: Math.max(texts.height, trailingRow.height)
  width: parent ? parent.width : implicitWidth
  height: implicitHeight

  Column {
    id: texts
    spacing: 4
    width: parent.width - (trailingRow.width > 0 ? trailingRow.width + 16 : 0)

    Text {
      width: parent.width
      text: root.title
      wrapMode: Text.Wrap
      color: Theme.ink
      font: Type.serif(root.titleSize)
      Accessible.role: Accessible.Heading
      Accessible.name: text
    }
    Text {
      visible: root.summary !== ""
      width: parent.width
      text: root.summary
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.body)
    }
  }

  Row {
    id: trailingRow
    anchors.right: parent.right
    spacing: 8
  }
}
