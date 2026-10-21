import QtQuick
import "../design"
import "../parts"
import "library"
import "library/LibraryModel.js" as Model

// Dictionary: saved spellings grouped by written form, the New word and Edit sheets, and the Import CSV sheet. Every change
// runs a control_library.py verb through the shell and gets the whole library back, so the list is always what is on disk.
// Edit and Remove send the saved written form as the expect value, so a spelling changed elsewhere is refused, not overwritten.
Item {
  id: root

  property var backend: ({})
  property bool active: false
  signal request(string command, var args)

  readonly property var results: backend && backend.results ? backend.results : ({})
  readonly property bool editing: sheetKind !== ""
  readonly property var groups: library ? Model.groupSpellings(library.entries) : []
  readonly property bool writable: library !== null && library.writable !== false
  readonly property bool restartNeeded: Model.adoptedConfig(results, ["spellings-add", "spellings-edit", "spellings-remove", "spellings-import"])
  property var library: null
  property string listError: ""
  property string sheetKind: ""
  property string sheetError: ""
  property var importPreview: null
  property string importPath: ""

  implicitHeight: content.implicitHeight

  function refresh() { tracker.send("spellings-list", []) }

  function closeSheet() {
    sheetKind = ""
    sheetError = ""
  }

  function openWord(pair) {
    sheetError = ""
    wordSheet.pair = pair
    sheetKind = "word"
  }

  function openImport() {
    sheetError = ""
    importPreview = null
    importPath = ""
    sheetKind = "import"
  }

  function absorb(reply) {
    var next = Model.libraryFrom(reply, "spellings")
    if (next) library = next
    return next !== null
  }

  Component.onCompleted: Qt.callLater(refresh)
  onActiveChanged: if (active && !tracker.waiting) refresh()

  RequestTracker {
    id: tracker
    backend: root.backend
    onDispatch: function(command, args) { root.request(command, args) }
    onFinished: function(command, reply) {
      if (reply.error) {
        if (command === "spellings-list") root.listError = String(reply.error)
        else {
          root.sheetError = String(reply.error)
          if (command === "spellings-import-preview") root.importPreview = null
          // A refused change usually means the file moved. Show the current list behind the sheet.
          else root.refresh()
        }
        return
      }
      if (command === "spellings-import-preview") {
        if (reply.problem === undefined && !reply.rows) { root.sheetError = "Mouthtype did not return a preview"; return }
        root.importPreview = reply
        root.importPath = importSheet.pathText.trim()
        root.sheetError = ""
        return
      }
      if (!root.absorb(reply)) {
        if (command === "spellings-list") root.listError = "Mouthtype did not return the dictionary"
        else root.sheetError = "Mouthtype did not confirm the change"
        return
      }
      root.listError = ""
      if (command !== "spellings-list") root.closeSheet()
    }
  }

  Column {
    id: content
    width: root.width
    spacing: 18

    DesignPageHeader {
      width: parent.width
      title: "Your names, spelled right."
      summary: "Teach Mouthtype the words it keeps mishearing. Save a spelling once and it sticks."
    }

    Item {
      width: parent.width
      height: toolbar.height
      Row {
        id: toolbar
        anchors.right: parent.right
        spacing: 8
        DesignSecondaryButton {
          text: "Import CSV…"
          enabled: root.writable
          onActivated: root.openImport()
        }
        DesignPrimaryButton {
          text: "+ New word"
          enabled: root.writable
          onActivated: root.openWord(null)
        }
      }
    }

    DesignCard {
      visible: root.restartNeeded
      width: parent.width
      DesignRow {
        title: "Restart Mouthtype to use this dictionary"
        detail: "The first save created the dictionary file and pointed linux.json at it. A service that is already running read its paths at start, so it applies the file after a restart."
        Icon { name: "warning"; size: 24; color: Theme.ink2 }
      }
    }

    DesignCard {
      visible: root.listError !== "" || (root.library !== null && !!root.library.problem)
      width: parent.width
      DesignRow {
        title: "The dictionary could not be read"
        detail: root.listError !== "" ? root.listError : (root.library && root.library.problem ? root.library.problem : "")
        Icon { name: "warning"; size: 24; color: Theme.danger }
        DesignSecondaryButton { text: "Try again"; onActivated: root.refresh() }
      }
    }

    DesignCard {
      visible: root.library !== null && !root.library.problem && root.groups.length === 0
      width: parent.width
      DesignRow {
        title: "No saved spellings yet"
        detail: "Add a word Mouthtype keeps getting wrong, or import a CSV of names."
      }
    }

    DesignCard {
      visible: root.groups.length > 0
      width: parent.width

      Item {
        width: parent.width
        height: columnTitles.height + 16
        Row {
          id: columnTitles
          x: 16
          y: 8
          spacing: 12
          Item { width: 24; height: 1 }
          Text { width: 160; text: "Written"; color: Theme.ink3; font: Type.eyebrow }
          Text { text: "Heard as"; color: Theme.ink3; font: Type.eyebrow }
        }
      }

      Repeater {
        model: root.groups
        delegate: WordRow {
          required property var modelData
          group: modelData
          onEditRequested: function(pair) { root.openWord(pair) }
        }
      }
    }

    Text {
      visible: root.library !== null && root.library.count > 0
      x: 4
      width: parent.width - 8
      text: root.library ? root.library.count + (root.library.count === 1 ? " saved spelling." : " saved spellings.") + " Click a word to edit it or remove it." : ""
      wrapMode: Text.Wrap
      color: Theme.ink3
      font: Type.sans(Type.caption)
    }
  }

  WordSheet {
    id: wordSheet
    open: root.sheetKind === "word"
    busy: tracker.waiting && root.sheetKind === "word"
    error: root.sheetKind === "word" ? root.sheetError : ""
    onCancelRequested: root.closeSheet()
    onSubmitted: function(heard, written) {
      root.sheetError = ""
      if (wordSheet.pair) tracker.send("spellings-edit", [wordSheet.pair.heard, heard, written, wordSheet.pair.written])
      else tracker.send("spellings-add", [heard, written])
    }
    onRemoveRequested: {
      root.sheetError = ""
      tracker.send("spellings-remove", [wordSheet.pair.heard, wordSheet.pair.written])
    }
  }

  ImportCsvSheet {
    id: importSheet
    open: root.sheetKind === "import"
    busy: tracker.waiting && root.sheetKind === "import"
    error: root.sheetKind === "import" ? root.sheetError : ""
    preview: root.importPreview
    previewPath: root.importPath
    onCancelRequested: root.closeSheet()
    onPreviewRequested: function(path) {
      root.sheetError = ""
      tracker.send("spellings-import-preview", [path])
    }
    onImportRequested: function(path, digest, csvDigest) {
      root.sheetError = ""
      tracker.send("spellings-import", [path, digest, csvDigest])
    }
  }
}
