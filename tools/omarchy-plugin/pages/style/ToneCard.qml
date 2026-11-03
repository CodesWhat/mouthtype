import QtQuick
import "../../design"

// One tone: the serif name, what it does, and the context's own dictation as that tone makes it. `lines` is the backend's
// samples[].lines, [{ spoken, engine, styled }]. The chosen card gets an ink border and a lime check.
Item {
  id: root

  property string title: ""
  property string blurb: ""
  property var lines: []
  property bool selected: false
  signal activated()

  implicitHeight: content.implicitHeight + 26
  activeFocusOnTab: true

  Rectangle {
    anchors.fill: parent
    radius: Theme.cardRadius
    color: Theme.surface
    border.width: root.selected ? 1.5 : 1
    border.color: root.selected ? Theme.ink : Theme.hair2
  }

  Column {
    id: content
    x: 14
    y: 14
    width: parent.width - 28
    spacing: 8

    Text {
      width: parent.width - (root.selected ? 26 : 0)
      text: root.title
      wrapMode: Text.Wrap
      color: Theme.ink
      font: Type.serif(Type.display)
    }
    Text {
      width: parent.width
      text: root.blurb
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.detail)
    }
    Rectangle {
      width: parent.width
      height: lineColumn.height + 18
      radius: 8
      color: Theme.bg
      Column {
        id: lineColumn
        x: 11
        y: 9
        width: parent.width - 22
        spacing: 2
        Repeater {
          model: root.lines
          delegate: MarkedText {
            required property var modelData
            width: lineColumn.width
            spoken: modelData.spoken
            styled: modelData.styled
          }
        }
      }
    }
  }

  Rectangle {
    visible: root.selected
    x: parent.width - 30
    y: 12
    width: 18
    height: 18
    radius: 9
    color: Theme.accent
    Icon { anchors.centerIn: parent; name: "check"; size: 14; color: Theme.onAccent }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: Theme.cardRadius + 3
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus(); root.activated() }
  }
  Keys.onSpacePressed: activated()
  Keys.onReturnPressed: activated()

  Accessible.role: Accessible.RadioButton
  Accessible.name: title + " tone"
  Accessible.checked: selected
  Accessible.description: blurb
  Accessible.onPressAction: activated()
}
