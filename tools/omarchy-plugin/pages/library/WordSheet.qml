import QtQuick
import "../../design"
import "../../parts"

// New word and Edit word. `pair` is null for a new word, or the saved { heard, written, starred, warning } being edited. The
// page passes the pair's written form back with every edit and remove as the stale-check value.
LibrarySheet {
  id: root

  property var pair: null
  readonly property bool isEdit: pair !== null
  readonly property string writtenText: writtenField.text.trim()
  readonly property string heardText: heardField.text.trim()
  property bool removeArmed: false
  signal submitted(string heard, string written)
  signal removeRequested()

  eyebrow: isEdit ? "Edit word" : "New word"
  title: isEdit ? "Change a spelling." : "Save a spelling."
  saveEnabled: writtenText !== "" && heardText !== ""
  note: "CTRL ↵ SAVES · ESC CANCELS"
  noteMono: true
  focusTarget: writtenField
  onSaveRequested: submitted(heardText, writtenText)

  onOpenChanged: {
    removeArmed = false
    if (!open) return
    writtenField.text = pair ? pair.written : ""
    heardField.text = pair ? pair.heard : ""
  }

  footerLeft: [
    DesignSecondaryButton {
      visible: root.isEdit
      text: root.removeArmed ? "Click again to remove" : "Remove"
      enabled: !root.busy
      onActivated: {
        if (root.removeArmed) root.removeRequested()
        else root.removeArmed = true
      }
    }
  ]

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Written" }
    FieldBox {
      id: writtenField
      width: parent.width
      hint: "Sean"
      onAccepted: heardField.forceActiveFocus()
      onTextEdited: root.removeArmed = false
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Heard as" }
    FieldBox {
      id: heardField
      width: parent.width
      hint: "shawn"
      onAccepted: if (root.saveEnabled) root.submitted(root.heardText, root.writtenText)
      onTextEdited: root.removeArmed = false
    }
    Text {
      x: 4
      width: parent.width - 8
      text: "What Mouthtype hears when you say it. Whitespace runs count as one space and case is ignored."
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
  }
}
