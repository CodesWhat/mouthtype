import QtQuick
import "../design"
import "../parts"
import "library"
import "library/LibraryModel.js" as Model

// Transforms: the phrases you say and the text typed instead, a New transform sheet, and the five selection transforms with
// the model status from `transform-status`. Edit and Remove send the saved expansion as the expect value.
Item {
  id: root

  property var backend: ({})
  property bool active: false
  signal request(string command, var args)

  readonly property var results: backend && backend.results ? backend.results : ({})
  readonly property bool editing: sheetOpen
  readonly property var entries: library ? library.entries : []
  readonly property bool writable: library !== null && library.writable !== false
  readonly property bool restartNeeded: Model.adoptedConfig(results, ["phrases-add", "phrases-edit", "phrases-remove"])
  readonly property var kinds: Model.transformKinds(status)
  property var library: null
  property var status: null
  property string listError: ""
  property bool sheetOpen: false
  property string sheetError: ""
  // Bumped whenever the sheet opens or closes. A reply for a request sent under an older value must not touch the current sheet.
  property int generation: 0
  property int sentGeneration: 0

  implicitHeight: content.implicitHeight

  function refresh() { tracker.send("phrases-list", []) }

  function send(command, args) {
    sentGeneration = generation
    return tracker.send(command, args)
  }

  function openSheet(entry) {
    sheetError = ""
    sheet.pair = entry
    generation++
    sheetOpen = true
  }

  function closeSheet() {
    generation++
    sheetOpen = false
    sheetError = ""
  }

  Component.onCompleted: Qt.callLater(refresh)
  onActiveChanged: if (active && !tracker.waiting) refresh()

  RequestTracker {
    id: tracker
    backend: root.backend
    onDispatch: function(command, args) { root.request(command, args) }
    onFinished: function(command, reply) {
      if (command === "transform-status") {
        // A failed status read leaves the rows on "checking" with the reason below them; it is not a page error.
        root.status = reply.error ? { kinds: [], model: { state: "unavailable", reason: String(reply.error) }, error: String(reply.error) } : reply
        return
      }
      var current = root.sentGeneration === root.generation
      if (reply.error) {
        if (command === "phrases-list") root.listError = String(reply.error)
        else {
          if (current) root.sheetError = String(reply.error)
          root.refresh()
        }
        return
      }
      var next = Model.libraryFrom(reply, "phrases")
      if (!next) {
        if (command === "phrases-list") root.listError = "Mouthtype did not return the transforms"
        else if (current) root.sheetError = "Mouthtype did not confirm the change"
        return
      }
      root.library = next
      root.listError = ""
      if (command === "phrases-list") tracker.send("transform-status", [])
      else if (current) root.closeSheet()
    }
  }

  Column {
    id: content
    width: root.width
    spacing: 18

    DesignPageHeader {
      width: parent.width
      title: "Say this, get that."
      summary: "A short phrase you say, and the exact text Mouthtype types instead. Plus what it can do to text you’ve selected."
    }

    DesignCard {
      visible: root.restartNeeded
      width: parent.width
      DesignRow {
        title: "Restart Mouthtype to use these transforms"
        detail: "The first save created the transforms file and pointed linux.json at it. A service that is already running read its paths at start, so it applies the file after a restart."
        Icon { name: "warning"; size: 24; color: Theme.ink2 }
      }
    }

    DesignCard {
      visible: root.listError !== "" || (root.library !== null && !!root.library.problem)
      width: parent.width
      DesignRow {
        title: "The transforms could not be read"
        detail: root.listError !== "" ? root.listError : (root.library && root.library.problem ? root.library.problem : "")
        Icon { name: "warning"; size: 24; color: Theme.danger }
        DesignSecondaryButton { text: "Try again"; onActivated: root.refresh() }
      }
    }

    Column {
      width: parent.width
      spacing: 6
      DesignEyebrow { text: "When you say" }
      DesignCard {
        width: parent.width

        Repeater {
          model: root.entries
          delegate: PhraseRow {
            required property var modelData
            required property int index
            entry: modelData
            first: index === 0
            onActivated: root.openSheet(modelData)
          }
        }

        DesignRow {
          visible: root.library !== null && root.entries.length === 0 && !root.library.problem
          title: "No transforms yet"
          detail: "Add a phrase you say often, like “my work email”, and the text to type for it."
        }

        DesignRow {
          title: "New transform"
          clickable: root.writable
          enabled: root.writable
          onActivated: root.openSheet(null)
          Icon { name: "plus"; size: 24; color: Theme.ink2 }
        }
      }
      Text {
        x: 4
        width: parent.width - 8
        text: "Whole phrases, any capitalization."
        wrapMode: Text.Wrap
        color: Theme.ink3
        font: Type.sans(Type.caption)
      }
    }

    Column {
      width: parent.width
      spacing: 6
      DesignEyebrow { text: "On selected text" }
      DesignCard {
        width: parent.width

        Repeater {
          model: root.kinds
          delegate: Item {
            id: kindRow
            required property var modelData
            required property int index
            readonly property var modelState: Model.modelStatus(modelData, root.status)
            width: parent ? parent.width : 0
            height: Math.max(42, Math.max(titleText.height, descText.height, statusRow.height) + 16)

            Rectangle {
              visible: kindRow.index > 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: 1
              color: Theme.hair2
            }

            Row {
              x: 14
              y: 8
              width: parent.width - 26
              spacing: 12
              Text {
                id: titleText
                width: 130
                text: kindRow.modelData.title
                wrapMode: Text.Wrap
                color: Theme.ink
                font: Type.sans(Type.body, "medium")
              }
              Text {
                id: descText
                width: parent.width - 130 - 12 - statusRow.width - 12
                text: kindRow.modelData.description
                wrapMode: Text.Wrap
                color: Theme.ink2
                font: Type.sans(Type.caption)
              }
              Row {
                id: statusRow
                spacing: 5
                Rectangle {
                  visible: kindRow.modelState.ready
                  y: (statusText.height - height) / 2
                  width: 6
                  height: 6
                  radius: 3
                  color: Theme.accent
                }
                Text {
                  id: statusText
                  text: kindRow.modelState.text
                  color: Theme.ink3
                  font: Type.eyebrow
                }
              }
            }
          }
        }
      }
      Text {
        x: 4
        width: parent.width - 8
        text: (Model.modelReason(root.status) !== "" ? Model.modelReason(root.status) + " " : "")
          + "You review the result before anything is replaced."
        wrapMode: Text.Wrap
        color: Theme.ink3
        font: Type.sans(Type.caption)
      }
    }
  }

  TransformSheet {
    id: sheet
    open: root.sheetOpen
    busy: tracker.waiting && root.sheetOpen
    error: root.sheetOpen ? root.sheetError : ""
    onCancelRequested: root.closeSheet()
    onSubmitted: function(trigger, expansion) {
      root.sheetError = ""
      if (sheet.pair) root.send("phrases-edit", [sheet.pair.trigger, trigger, expansion, sheet.pair.expansion])
      else root.send("phrases-add", [trigger, expansion])
    }
    onRemoveRequested: {
      root.sheetError = ""
      root.send("phrases-remove", [sheet.pair.trigger, sheet.pair.expansion])
    }
  }
}
