import QtQuick

// A key cap: mono 12 on the key colour, radius 6, hair border, with a one pixel lip underneath.
Item {
  id: root

  property string text: ""

  implicitWidth: label.implicitWidth + 18
  implicitHeight: label.implicitHeight + 6
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    anchors.topMargin: 1
    anchors.bottomMargin: -1
    radius: 6
    color: Theme.hair
  }
  Rectangle {
    anchors.fill: parent
    radius: 6
    color: Theme.key
    border.width: 1
    border.color: Theme.hair
  }
  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: Theme.ink
    font: Type.mono(Type.detail)
  }

  Accessible.role: Accessible.StaticText
  Accessible.name: text
}
