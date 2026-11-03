import QtQuick
import "../../design"

// One cleanup level: its serif name, what it does, the same messy take as that level returns it, and the model status. The
// card chooses the level when it can run; Fast and Thorough show a Prepare link until their model is there.
Item {
  id: root

  property string title: ""
  property string blurb: ""
  property string sample: ""
  property string status: ""
  property bool selected: false
  property bool usable: true
  property bool canPrepare: false
  signal activated()
  signal prepareRequested()

  implicitHeight: content.implicitHeight + 26
  activeFocusOnTab: true
  opacity: usable || selected ? 1 : 0.8

  Rectangle {
    anchors.fill: parent
    radius: Theme.cardRadius
    color: Theme.surface
    border.width: root.selected ? 1.5 : 1
    border.color: root.selected ? Theme.ink : Theme.hair2
  }
  MouseArea {
    anchors.fill: parent
    cursorShape: root.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: { root.forceActiveFocus(); if (root.usable) root.activated() }
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
      font: Type.serif(20)
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
      height: sampleText.height + 18
      radius: 8
      color: Theme.bg
      Text {
        id: sampleText
        x: 11
        y: 9
        width: parent.width - 22
        text: root.sample
        wrapMode: Text.Wrap
        color: Theme.ink2
        lineHeight: 1.15
        font: Type.sans(Type.caption)
      }
    }
    Row {
      spacing: 10
      Text {
        text: root.status
        wrapMode: Text.NoWrap
        color: Theme.ink3
        font: Type.eyebrow
        anchors.verticalCenter: parent.verticalCenter
      }
      LinkText {
        visible: root.canPrepare
        text: "Prepare…"
        anchors.verticalCenter: parent.verticalCenter
        onActivated: root.prepareRequested()
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
  Keys.onSpacePressed: if (usable) activated()
  Keys.onReturnPressed: if (usable) activated()

  Accessible.role: Accessible.RadioButton
  Accessible.name: title + " cleanup"
  Accessible.checked: selected
  Accessible.description: sample
  Accessible.onPressAction: if (usable) activated()
}
