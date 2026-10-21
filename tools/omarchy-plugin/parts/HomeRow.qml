import QtQuick
import "../design"

// One take on Home: the text, its time, and a Copy or Recover button that shows while the row is hovered or focused.
// Sits directly in a DesignCard; forwards the card's corner flags to the DesignRow inside.
Item {
  id: root

  property string title: ""
  property string detail: ""
  property string buttonText: ""
  property bool buttonEnabled: true
  property bool dim: false
  property bool cardFirst: true
  property bool cardLast: true
  signal activated()
  signal buttonActivated()

  width: parent ? parent.width : 320
  implicitHeight: row.implicitHeight
  height: row.height

  HoverHandler { id: hover }

  DesignRow {
    id: row
    title: root.title
    detail: root.detail
    clickable: true
    cardFirst: root.cardFirst
    cardLast: root.cardLast
    onActivated: root.activated()

    DesignSecondaryButton {
      id: button
      visible: root.buttonText !== ""
      enabled: root.buttonEnabled
      text: root.buttonText
      opacity: hover.hovered || activeFocus ? (enabled ? 1 : 0.45) : 0
      onActivated: root.buttonActivated()
    }
  }
}
