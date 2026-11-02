import QtQuick
import "../../design"
import "../../parts"
import "LibraryModel.js" as Model

// Import CSV: pick a file by path, preview the rows, then import exactly what was previewed. The Omarchy file chooser the
// plugin already has only opens audio files and starts a transcription, so this sheet takes a path instead.
// `preview` is the spellings-import-preview reply for `previewPath`; its digest and csv_digest go back with the import.
LibrarySheet {
  id: root

  property var preview: null
  property string previewPath: ""
  property alias pathText: pathField.text
  readonly property bool previewCurrent: preview !== null && previewPath === pathField.text.trim()
  readonly property bool canImport: previewCurrent && preview.can_import === true
  readonly property var rows: preview && preview.rows ? Model.visibleImportRows(preview.rows) : ({ shown: [], hidden: 0 })
  signal previewRequested(string path)
  signal importRequested(string path, string digest, string csvDigest)

  eyebrow: "Import CSV" + (preview && preview.file ? " · " + preview.file : "")
  title: "Import spellings."
  sheetWidth: 640
  focusTarget: pathField
  saveText: Model.importButtonText(preview ? preview.counts : null)
  saveEnabled: canImport
  note: !preview ? "Nothing changes until you import." : Model.importFootnote(preview)
  onSaveRequested: importRequested(previewPath, preview.digest || "", preview.csv_digest || "")

  onOpenChanged: if (open) { pathField.text = previewPath }

  function runPreview() {
    var path = pathField.text.trim()
    if (path !== "") previewRequested(path)
  }

  Text {
    width: parent.width
    text: "A heard,written pair per row, or a single name column. Existing spellings stay as they are."
    wrapMode: Text.Wrap
    color: Theme.ink2
    font: Type.sans(Type.detail)
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "CSV file" }
    Row {
      width: parent.width
      spacing: 8
      FieldBox {
        id: pathField
        width: parent.width - previewButton.width - 8
        hint: "Path to a .csv file, for example ~/names.csv"
        onAccepted: root.runPreview()
      }
      DesignSecondaryButton {
        id: previewButton
        anchors.verticalCenter: pathField.verticalCenter
        text: root.preview !== null && root.previewCurrent ? "Reload" : "Preview"
        enabled: pathField.text.trim() !== "" && !root.busy
        onActivated: root.runPreview()
      }
    }
  }

  // Summary line: new · already saved · errors.
  Row {
    visible: root.preview !== null && !root.preview.problem
    spacing: 14
    Repeater {
      model: root.preview ? Model.importSummary(root.preview.counts) : []
      delegate: Row {
        id: part
        required property var modelData
        spacing: 5
        Text {
          text: part.modelData.count
          color: part.modelData.bad ? Theme.danger : Theme.ink
          font: Type.mono(Type.eyebrowSize)
        }
        Text {
          text: part.modelData.label.toUpperCase()
          color: part.modelData.bad ? Theme.danger : Theme.ink3
          font: Type.eyebrow
        }
      }
    }
  }

  DesignCard {
    visible: root.preview !== null && !root.preview.problem && root.preview.rows.length > 0
    width: parent.width

    Item {
      width: parent.width
      height: tableHeader.height + 16
      Row {
        id: tableHeader
        x: 14
        y: 8
        width: parent.width - 28
        spacing: 12
        readonly property real flexWidth: (width - 36 - 36 - 170) / 2
        Text { width: 36; text: "Row"; color: Theme.ink3; font: Type.eyebrow }
        Text { width: tableHeader.flexWidth; text: "Heard as"; color: Theme.ink3; font: Type.eyebrow }
        Text { width: tableHeader.flexWidth; text: "Write as"; color: Theme.ink3; font: Type.eyebrow }
        Text { width: 170; text: "Result"; color: Theme.ink3; font: Type.eyebrow }
      }
    }

    Repeater {
      model: root.rows.shown
      delegate: Item {
        id: line
        required property var modelData
        readonly property bool invalid: modelData.result === "invalid"
        readonly property real flexWidth: (width - 28 - 36 - 36 - 170) / 2
        readonly property string sub: invalid ? String(modelData.label || "") : String(modelData.warning || "")
        width: parent ? parent.width : 0
        height: Math.max(cells.height, 0) + 16

        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.hair2 }

        Row {
          id: cells
          x: 14
          y: 8
          spacing: 12
          Text {
            width: 36
            text: line.modelData.row
            color: Theme.ink3
            font: Type.mono(Type.caption)
          }
          Text {
            width: line.flexWidth
            text: line.modelData.heard === "" ? "Blank" : line.modelData.heard
            wrapMode: Text.Wrap
            color: line.invalid ? Theme.danger : (line.modelData.heard === "" ? Theme.ink3 : Theme.ink)
            font.family: Type.sans(Type.body).family
            font.pixelSize: Type.body
            font.italic: line.modelData.heard === ""
          }
          Text {
            width: line.flexWidth
            text: line.modelData.written
            wrapMode: Text.Wrap
            color: line.invalid ? Theme.danger : Theme.ink
            font: Type.sans(Type.body)
          }
          Column {
            width: 170
            spacing: 1
            Text {
              width: parent.width
              text: line.invalid ? "Error" : (line.modelData.result === "add" ? "New" : String(line.modelData.label || ""))
              wrapMode: Text.Wrap
              color: line.invalid ? Theme.danger : Theme.ink2
              font: Type.sans(Type.detail, line.invalid ? "medium" : undefined)
            }
            Text {
              visible: line.sub !== ""
              width: parent.width
              text: line.sub
              wrapMode: Text.Wrap
              color: Theme.ink3
              font: Type.sans(Type.caption)
            }
          }
        }
      }
    }

    Item {
      visible: root.rows.hidden > 0
      width: parent.width
      height: moreText.implicitHeight + 16
      Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.hair2 }
      Text {
        id: moreText
        x: 14
        y: 8
        width: parent.width - 28
        text: "… and " + root.rows.hidden + " more " + (root.rows.hidden === 1 ? "row" : "rows")
        wrapMode: Text.Wrap
        color: Theme.ink3
        font: Type.sans(Type.caption)
      }
    }
  }
}
