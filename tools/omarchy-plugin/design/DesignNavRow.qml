import QtQuick

// A navigation row: an 18 px Phosphor icon, a title, selected on the sel tint only. There is no lime selection bar. Sidebar rows
// are 40 high around the icon; the Settings modal nav uses 34.
Item {
  id: root

  property string title: ""
  property string iconName: ""
  property bool selected: false
  property real rowHeight: 40
  // False after a mouse click or a page change from outside the keys: the row keeps focus but draws no ring. Losing focus
  // re-arms it, so Tab and the arrow keys show the ring again.
  property bool ringShown: true
  signal activated()

  implicitWidth: 200
  implicitHeight: Math.max(rowHeight, navLabel.height + 16)
  width: parent ? parent.width : implicitWidth
  height: implicitHeight
  activeFocusOnTab: true

  Rectangle {
    anchors.fill: parent
    radius: Theme.navRadius
    color: Theme.sel
    visible: root.selected || mouse.containsMouse
    opacity: root.selected ? 1 : 0.6
  }
  Rectangle {
    anchors.fill: parent
    radius: Theme.navRadius
    color: "transparent"
    border.width: 2
    border.color: Theme.focus
    visible: root.activeFocus && root.ringShown
  }
  Icon {
    x: 10
    anchors.verticalCenter: parent.verticalCenter
    name: root.iconName
    size: 18
    color: Theme.ink2
  }
  Text {
    id: navLabel
    x: 10 + 18 + 12
    width: parent.width - x - 10
    anchors.verticalCenter: parent.verticalCenter
    text: root.title
    wrapMode: Text.Wrap
    color: Theme.ink
    font: Type.sans(Type.body, "medium")
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.ringShown = false; root.forceActiveFocus(); root.activated() }
  }

  onActiveFocusChanged: if (!activeFocus) ringShown = true

  Keys.onSpacePressed: activated()
  Keys.onReturnPressed: activated()

  Accessible.role: Accessible.Button
  Accessible.name: title
  Accessible.selected: selected
  Accessible.onPressAction: activated()
}
