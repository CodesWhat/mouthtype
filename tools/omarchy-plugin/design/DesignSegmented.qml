import QtQuick

// Segmented control on the sel tint with a surface selected pill. `model` is a list of strings or of { label, dot } objects
// (dot is an optional colour). Left and right arrows move the selection when the control has focus.
Item {
  id: root

  property var model: []
  property int currentIndex: 0
  property string text: ""
  signal activated(int index)

  implicitWidth: strip.implicitWidth + 4
  implicitHeight: 28
  width: implicitWidth
  height: implicitHeight
  activeFocusOnTab: true
  opacity: enabled ? 1 : 0.45

  function labelOf(item) { return typeof item === "string" ? item : item.label }
  function dotOf(item) { return typeof item === "string" ? undefined : item.dot }

  function select(index) {
    if (index < 0 || index >= model.length || index === currentIndex) return
    currentIndex = index
    activated(index)
  }

  Rectangle {
    anchors.fill: parent
    radius: Theme.navRadius
    color: Theme.sel
  }

  Row {
    id: strip
    x: 2
    y: 2
    spacing: 2

    Repeater {
      model: root.model
      delegate: Item {
        id: seg
        required property var modelData
        required property int index
        readonly property bool selected: index === root.currentIndex
        readonly property var dotColor: root.dotOf(modelData)

        implicitWidth: segRow.implicitWidth + 24
        implicitHeight: 24
        width: implicitWidth
        height: implicitHeight

        Rectangle {
          anchors.fill: parent
          radius: 6
          color: Theme.surface
          visible: seg.selected
        }
        Row {
          id: segRow
          anchors.centerIn: parent
          spacing: 6
          Rectangle {
            visible: seg.dotColor !== undefined
            width: 9
            height: 9
            radius: 4.5
            anchors.verticalCenter: parent.verticalCenter
            color: seg.dotColor !== undefined ? seg.dotColor : "transparent"
          }
          Text {
            text: root.labelOf(seg.modelData)
            color: seg.selected ? Theme.ink : Theme.ink2
            font: Type.sans(Type.detail, seg.selected ? "medium" : undefined)
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.forceActiveFocus(); root.select(seg.index) }
        }
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: Theme.navRadius + 3
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus
  }

  Keys.onLeftPressed: select(currentIndex - 1)
  Keys.onRightPressed: select(currentIndex + 1)

  Accessible.role: Accessible.RadioButton
  Accessible.name: text
}
