import QtQuick
import "../design"
import "../parts"

// Transcribe Audio File: a file row with a status chip, the raw transcript card, Copy and Save Text. Same import-* verbs as the
// old menu page. The result is the raw recognition, so the card carries a RAW tag.
Column {
  id: root

  property var host: null
  readonly property bool editing: importField.activeFocus
  readonly property var file: host ? host.fileImport : ({ state: "off" })
  readonly property bool idle: !!host && (host.sessionState === "off" || host.sessionState === "idle")
  readonly property string transcriptText: host && host.importText !== "" ? host.importText
    : (file.state === "finished" && host && host.importTextFor === "" ? "Loading…" : "")
  readonly property int wordCount: transcriptText === "" || transcriptText === "Loading…" ? 0 : transcriptText.trim().split(/\s+/).length

  width: parent ? parent.width : 520
  spacing: 18

  onVisibleChanged: if (visible && host && host.importHasResult && host.importTextFor !== (file.id || "")) host.loadImportText()
  Component.onCompleted: if (host && host.importHasResult && host.importTextFor !== (file.id || "")) host.loadImportText()

  DesignPageHeader {
    width: parent.width
    title: "Transcribe Audio File"
    summary: "Files up to 10 minutes and 512 MB in WAV, AIFF or M4A."
    DesignSecondaryButton { text: "Back"; onActivated: root.host.openPage("home") }
  }

  DesignCard {
    width: parent.width
    DesignRow {
      title: root.host ? root.host.importLabel() : ""
      detail: root.file.format ? String(root.file.format).toUpperCase() : "No file chosen"
      Rectangle {
        visible: root.host && (root.host.importActive || root.host.importHasResult || root.file.state === "failed" || root.file.state === "cancelled")
        width: chip.implicitWidth + 16
        height: 22
        radius: 11
        color: root.file.state === "failed" ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.14) : Theme.sel
        Text {
          id: chip
          anchors.centerIn: parent
          text: root.host && root.host.importActive ? "Transcribing" : root.file.state === "finished" ? "Done" : root.file.state === "empty" ? "No speech" : root.file.state === "failed" ? "Failed" : "Cancelled"
          color: root.file.state === "failed" ? Theme.danger : Theme.ink
          font: Type.eyebrow
        }
      }
      DesignSecondaryButton {
        visible: root.host && root.host.importActive
        text: "Cancel"
        enabled: root.file.state !== "cancelling"
        onActivated: root.host.run(["import-cancel"])
      }
      DesignSecondaryButton {
        visible: root.host && !root.host.importActive
        text: "Choose Another…"
        enabled: root.idle
        onActivated: root.host.run(["import-pick"])
      }
    }
    Item {
      visible: !!root.host && root.host.importActive
      width: parent.width
      height: 16
      Rectangle {
        x: 14
        y: 6
        width: parent.width - 28
        height: 4
        radius: 2
        color: Theme.track
        clip: true
        Rectangle {
          id: sweep
          width: parent.width * 0.3
          height: parent.height
          radius: 2
          color: Theme.accent
          SequentialAnimation on x {
            loops: Animation.Infinite
            running: sweep.visible && root.visible
            NumberAnimation { from: -sweep.width; to: sweep.parent.width; duration: 1200 }
          }
        }
      }
    }
  }

  Text {
    visible: root.file.state === "failed" && (root.file.message || "") !== ""
    width: parent.width
    text: root.file.message || ""
    wrapMode: Text.Wrap
    color: Theme.danger
    font: Type.sans(Type.detail)
  }

  Column {
    visible: root.file.state === "finished"
    width: parent.width
    spacing: 6
    Row {
      spacing: 8
      DesignEyebrow { text: root.wordCount + (root.wordCount === 1 ? " word" : " words") }
      Rectangle {
        height: 18
        width: rawTag.implicitWidth + 12
        radius: 4
        color: Theme.sel
        Text { id: rawTag; anchors.centerIn: parent; text: "Raw · no cleanup"; color: Theme.ink2; font: Type.eyebrow }
      }
    }
    DesignCard {
      width: parent.width
      Item {
        width: parent.width
        height: Math.min(Math.max(importField.contentHeight + 28, 56), 260)
        Flickable {
          anchors.fill: parent
          anchors.margins: 14
          contentWidth: width
          contentHeight: importField.contentHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          TextEdit {
            id: importField
            width: parent.width
            text: root.transcriptText
            readOnly: true
            selectByMouse: true
            selectByKeyboard: true
            wrapMode: TextEdit.Wrap
            color: Theme.ink
            selectionColor: Theme.accent
            selectedTextColor: Theme.onAccent
            font.family: root.host ? root.host.transcriptFont : Type.sansFamily
            font.pixelSize: Type.body
          }
        }
      }
    }
  }

  Row {
    visible: !!root.host && (root.host.importHasResult || root.host.importRetained)
    spacing: 8
    DesignPrimaryButton { text: "Copy"; enabled: !!root.host && root.host.importCanExport; onActivated: root.host.run(["import-copy"]) }
    DesignSecondaryButton { text: "Save Text…"; enabled: !!root.host && root.host.importCanExport; onActivated: root.host.run(["import-save"]) }
    DesignSecondaryButton {
      visible: !!root.host && !root.host.importActive && root.file.state !== "idle" && root.file.state !== "off"
      text: "Clear Result"
      onActivated: root.host.run(["import-forget"])
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.Wrap
    color: Theme.ink2
    font: Type.sans(Type.caption)
    text: "The result is the raw recognition: cleanup, saved spellings and phrases are not applied, nothing is pasted, and it is not added to Recent Dictations. Your original file is not changed."
  }
}
