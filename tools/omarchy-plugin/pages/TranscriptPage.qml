import QtQuick
import "../design"

// One saved dictation in full, opened from Home. Copy and Forget run the same verbs the old menu did.
Column {
  id: root

  property var host: null

  width: parent ? parent.width : 520
  spacing: 18

  DesignPageHeader {
    width: parent.width
    title: "Dictation"
    summary: "The saved text for this take."
    DesignSecondaryButton { text: "Back"; onActivated: root.host.openPage("home") }
  }

  DesignCard {
    width: parent.width
    Item {
      width: parent.width
      height: body.implicitHeight + 32
      Text {
        id: body
        x: 16
        y: 16
        width: parent.width - 32
        text: root.host ? root.host.transcript : ""
        wrapMode: Text.Wrap
        color: Theme.ink
        font.family: root.host ? root.host.transcriptFont : Type.sansFamily
        font.pixelSize: Type.body
      }
    }
  }

  Row {
    spacing: 8
    DesignPrimaryButton { text: "Copy Dictation"; onActivated: root.host.run(["copy", root.host.transcriptId]) }
    DesignSecondaryButton { text: "Forget This Dictation"; onActivated: root.host.run(["forget", root.host.transcriptId]) }
  }
}
