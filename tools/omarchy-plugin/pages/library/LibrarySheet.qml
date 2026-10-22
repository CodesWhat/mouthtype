import QtQuick
import "../../design"

// The frame for the Dictionary and Transforms sheets: a scrim, a centred card with an eyebrow, a serif title, the body, and a
// footer with a note on the left and Cancel and the primary button on the right. Esc cancels and Ctrl+Return saves. It moves
// itself onto the shell root when it opens, so the scrim covers the sidebar like the Settings modal's does.
Item {
  id: root

  property bool open: false
  property string eyebrow: ""
  property string title: ""
  property string summary: ""
  property string note: ""
  property bool noteMono: false
  property string error: ""
  property string saveText: "Save"
  property bool saveEnabled: true
  property bool busy: false
  property real sheetWidth: 560
  // Gets keyboard focus when the sheet opens.
  property Item focusTarget: null
  default property alias content: body.data
  property alias footerLeft: leftSlot.data
  signal cancelRequested()
  signal saveRequested()

  visible: open
  anchors.fill: parent
  z: 100

  function attach() {
    var item = root.parent
    while (item) {
      if (item.pageFiles !== undefined) { root.parent = item; return }
      item = item.parent
    }
  }

  onOpenChanged: {
    if (!open) return
    attach()
    Qt.callLater(function() { if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus() })
  }

  Shortcut {
    sequences: ["Ctrl+Return", "Ctrl+Enter"]
    enabled: root.open && root.saveEnabled && !root.busy
    onActivated: root.saveRequested()
  }

  Shortcut {
    sequence: "Escape"
    enabled: root.open
    onActivated: root.cancelRequested()
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.scrim
    // A click on the scrim does nothing: a stray click should not throw away what was typed.
    MouseArea { anchors.fill: parent }
  }

  Rectangle {
    id: card
    readonly property real errorBlock: root.error !== "" ? errorText.implicitHeight + 10 : 0
    anchors.centerIn: parent
    width: Math.min(root.sheetWidth, parent.width - 40)
    height: Math.min(22 + header.height + 14 + scroller.contentHeight + errorBlock + 14 + footer.height + 20, parent.height - 40)
    radius: 14
    color: Theme.bg
    border.width: 1
    border.color: Theme.hair2
    clip: true

    MouseArea { anchors.fill: parent }

    Column {
      id: header
      x: 24
      y: 22
      width: parent.width - 48
      spacing: 10

      Item {
        width: parent.width
        height: 28
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 36
          text: root.eyebrow
          wrapMode: Text.Wrap
          color: Theme.ink3
          font: Type.eyebrow
        }
        Rectangle {
          anchors.right: parent.right
          width: 28
          height: 28
          radius: 14
          color: Theme.sel
          Accessible.role: Accessible.Button
          Accessible.name: "Close without saving"
          Icon { anchors.centerIn: parent; name: "close"; size: 14; color: Theme.ink2 }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelRequested() }
        }
      }

      Column {
        width: parent.width
        spacing: 4
        Text {
          width: parent.width
          text: root.title
          wrapMode: Text.Wrap
          color: Theme.ink
          font: Type.serif(24)
          Accessible.role: Accessible.Heading
          Accessible.name: text
        }
        Text {
          visible: root.summary !== ""
          width: parent.width
          text: root.summary
          wrapMode: Text.Wrap
          color: Theme.ink2
          font: Type.sans(Type.detail)
        }
      }
    }

    Flickable {
      id: scroller
      x: 24
      anchors.top: header.bottom
      anchors.topMargin: 14
      width: parent.width - 48
      height: Math.max(0, parent.height - 22 - header.height - 14 - card.errorBlock - 14 - footer.height - 20)
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick

      Column {
        id: body
        width: scroller.width
        spacing: 14
      }
    }

    Text {
      id: errorText
      x: 24
      anchors.top: scroller.bottom
      anchors.topMargin: 10
      width: parent.width - 48
      visible: root.error !== ""
      text: root.error
      wrapMode: Text.Wrap
      color: Theme.danger
      font: Type.sans(Type.detail, "medium")
    }

    Item {
      id: footer
      x: 24
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 20
      width: parent.width - 48
      height: Math.max(buttons.height, noteBlock.height)

      Row {
        id: leftSlot
        spacing: 8
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: noteBlock
        anchors.left: leftSlot.right
        anchors.leftMargin: leftSlot.width > 0 ? 12 : 0
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - leftSlot.width - (leftSlot.width > 0 ? 12 : 0) - buttons.width - 16)
        text: root.note
        wrapMode: Text.Wrap
        color: Theme.ink3
        font: root.note.indexOf("↵") >= 0 ? Type.eyebrow : Type.sans(Type.caption)
      }

      Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
        DesignSecondaryButton { text: "Cancel"; onActivated: root.cancelRequested() }
        DesignPrimaryButton {
          text: root.busy ? "Working…" : root.saveText
          enabled: root.saveEnabled && !root.busy
          onActivated: root.saveRequested()
        }
      }
    }
  }
}
