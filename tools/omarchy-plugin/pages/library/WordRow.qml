import QtQuick
import "../../design"
import "LibraryModel.js" as Model

// One written form in the Dictionary list: a star when it is favoured, the written text, a chip per heard form, and the
// everyday-word warning under them. A click on a chip edits that pair, a click anywhere else edits the first.
Item {
  id: root

  property var group: ({ written: "", starred: false, pairs: [], warnings: [] })
  property bool first: false
  signal editRequested(var pair)

  readonly property color fillColor: Qt.tint(Theme.surface, Theme.sel)

  width: parent ? parent.width : 320
  implicitHeight: Math.max(40, content.height + 16)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    color: root.fillColor
    visible: rowHover.containsMouse
  }

  Rectangle {
    visible: !root.first
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: Theme.hair2
  }

  MouseArea {
    id: rowHover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.editRequested(root.group.pairs[0])
  }

  Row {
    id: content
    x: 16
    y: 8
    width: parent.width - 32
    spacing: 12

    Item {
      width: 24
      height: 24
      Text {
        anchors.centerIn: parent
        visible: root.group.starred
        text: "★"
        color: Theme.orange
        font: Type.sans(14)
        Accessible.name: "Favoured while recognising"
      }
    }

    Text {
      width: 160
      anchors.verticalCenter: undefined
      topPadding: 3
      text: root.group.written
      wrapMode: Text.Wrap
      color: Theme.ink
      font: Type.sans(Type.body, "medium")
    }

    Column {
      width: parent.width - 24 - 160 - 24
      spacing: 4

      Flow {
        width: parent.width
        spacing: 6
        Repeater {
          model: root.group.pairs
          delegate: MonoChip {
            id: chip
            required property var modelData
            maxWidth: 260
            text: modelData.heard
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.editRequested(chip.modelData)
            }
          }
        }
      }

      Repeater {
        model: root.group.warnings
        delegate: Row {
          id: warn
          required property var modelData
          width: parent.width
          spacing: 6
          Icon { y: 1; name: "warning"; size: 16; color: Theme.ink2 }
          Text {
            width: parent.width - 22
            text: warn.modelData
            wrapMode: Text.Wrap
            color: Theme.ink2
            font: Type.sans(Type.caption)
          }
        }
      }
    }
  }
}
