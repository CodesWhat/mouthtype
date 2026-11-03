import QtQuick
import "../../design"
import "LibraryModel.js" as Model

// One saved transform: the trigger as a mono chip, an arrow, what gets typed on one line with an edge fade, a kind tag and a
// chevron. The whole row opens the edit sheet.
Item {
  id: root

  property var entry: ({ trigger: "", expansion: "" })
  property bool first: false
  signal activated()

  readonly property color fillColor: hover.containsMouse ? Qt.tint(Theme.surface, Theme.sel) : Theme.surface

  width: parent ? parent.width : 320
  implicitHeight: 42
  height: implicitHeight

  Rectangle { anchors.fill: parent; color: root.fillColor }

  Rectangle {
    visible: !root.first
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: Theme.hair2
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  Item {
    x: 14
    width: parent.width - 26
    height: parent.height

    MonoChip {
      id: chip
      anchors.verticalCenter: parent.verticalCenter
      maxWidth: 150
      text: root.entry.trigger
    }

    Text {
      id: arrow
      x: 162
      anchors.verticalCenter: parent.verticalCenter
      text: "→"
      color: Theme.ink3
      font: Type.mono(Type.body)
    }

    EdgeFadeText {
      x: 188
      anchors.verticalCenter: parent.verticalCenter
      width: tag.x - 12 - x
      text: Model.previewText(root.entry.expansion)
      font: Type.sans(Type.body)
      fadeColor: root.fillColor
    }

    Text {
      id: tag
      anchors.right: chevron.left
      anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      text: Model.kindTag(root.entry.expansion)
      color: Theme.ink3
      font: Type.eyebrow
    }

    Icon {
      id: chevron
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      name: "chevron-right"
      size: 16
      color: Theme.ink3
    }
  }
}
