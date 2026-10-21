import QtQuick
import "../../design"

// The five Style tabs: text with a 2 px underline on the current one, a hairline under the row. Left and right move the tab.
Item {
  id: root

  property var titles: []
  property int currentIndex: 0
  signal activated(int index)

  implicitHeight: row.height + 1
  height: implicitHeight
  activeFocusOnTab: true

  Row {
    id: row
    spacing: 24

    Repeater {
      model: root.titles
      delegate: Item {
        id: tab
        required property string modelData
        required property int index
        readonly property bool selected: index === root.currentIndex
        width: label.implicitWidth + 4
        height: label.implicitHeight + 12

        Text {
          id: label
          x: 2
          y: 2
          text: tab.modelData
          wrapMode: Text.NoWrap
          color: tab.selected ? Theme.ink : Theme.ink2
          font: Type.sans(Type.body, "medium")
        }
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 2
          color: tab.selected ? Theme.ink : "transparent"
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.forceActiveFocus(); root.activated(tab.index) }
        }
        Accessible.role: Accessible.PageTab
        Accessible.name: tab.modelData
      }
    }
  }
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 0
    width: parent.width
    height: 1
    color: Theme.hair
    z: -1
  }
  Rectangle {
    anchors.fill: row
    anchors.margins: -4
    radius: 6
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }

  Keys.onLeftPressed: if (currentIndex > 0) activated(currentIndex - 1)
  Keys.onRightPressed: if (currentIndex < titles.length - 1) activated(currentIndex + 1)
}
