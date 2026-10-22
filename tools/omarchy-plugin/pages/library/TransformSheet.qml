import QtQuick
import "../../design"
import "../../parts"
import "LibraryModel.js" as Model

// New transform and Edit transform. `pair` is null for a new phrase, or the saved { trigger, expansion } being edited.
LibrarySheet {
  id: root

  property var pair: null
  readonly property bool isEdit: pair !== null
  readonly property string triggerText: triggerField.text.trim()
  readonly property string expansionText: expansionField.text
  readonly property bool usesClipboard: Model.variables(expansionField.text).clipboard === true
  property bool removeArmed: false
  // A recovered draft { trigger, expansion } to open a new transform with. Used once, by the next open.
  property var prefill: null
  readonly property bool dirty: triggerField.text !== (pair ? pair.trigger : "") || expansionField.text !== (pair ? pair.expansion : "")
  signal submitted(string trigger, string expansion)
  signal removeRequested()

  eyebrow: isEdit ? "Edit transform" : "New transform"
  title: isEdit ? "Change a transform." : "Save a transform."
  saveEnabled: triggerText !== "" && expansionText.trim() !== ""
  note: "CTRL ↵ SAVES · ESC CANCELS"
  noteMono: true
  focusTarget: triggerField
  sheetWidth: 600
  onSaveRequested: submitted(triggerText, expansionText)

  onOpenChanged: {
    removeArmed = false
    if (!open) return
    triggerField.text = pair ? pair.trigger : (prefill ? prefill.trigger || "" : "")
    expansionField.text = pair ? pair.expansion : (prefill ? prefill.expansion || "" : "")
    prefill = null
  }

  // The unsaved edits as a draft for control_library.py draft-save, or null when nothing was typed.
  function draftSnapshot() {
    if (!dirty || (triggerField.text === "" && expansionField.text === "")) return null
    return { kind: "phrase", trigger: triggerField.text, expansion: expansionField.text }
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
    DesignEyebrow { text: "When you say" }
    FieldBox {
      id: triggerField
      width: parent.width
      hint: "my work email"
      onAccepted: expansionField.forceFocus()
      onTextEdited: root.removeArmed = false
    }
    Text {
      x: 4
      width: parent.width - 8
      text: "Matches the whole phrase, any capitalization."
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Type instead" }
    AreaBox {
      id: expansionField
      width: parent.width
      hint: "What Mouthtype types. Press Return for a new line."
      area.onTextChanged: root.removeArmed = false
    }
    Row {
      spacing: 8
      DesignSecondaryButton { text: "+ Date"; onActivated: expansionField.insertText("{date}") }
      DesignSecondaryButton { text: "+ Clipboard"; onActivated: expansionField.insertText("{clipboard}") }
    }
    Text {
      x: 4
      width: parent.width - 8
      text: "{date} becomes today’s date; {clipboard} becomes whatever you copied before dictating."
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
    Text {
      visible: root.usesClipboard
      x: 4
      width: parent.width - 8
      text: "Clipboard text is only read when \"phrase_clipboard\" is true in linux.json (it needs wl-clipboard). With it off, dictation refuses while any transform uses {clipboard}."
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
  }
}
