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
  readonly property var allGroups: library ? Model.groupSpellings(library.entries) : []
  readonly property var groups: Model.filterGroups(allGroups, query)
  // Only the first `shown` matches get rows. The rest wait behind the Show more row.
  readonly property var shownGroups: groups.length > shown ? groups.slice(0, shown) : groups
  readonly property bool writable: library !== null && library.writable !== false
  readonly property bool restartNeeded: Model.adoptedConfig(results, ["spellings-add", "spellings-edit", "spellings-remove", "spellings-import"])
  property var library: null
  property string query: ""
  property int shown: Model.PAGE_ROWS
  property string listError: ""
  property string sheetKind: ""
  property string sheetError: ""
  property var importPreview: null
  property string importPath: ""
  // Bumped whenever a sheet opens or closes. A reply for a request sent under an older value must not touch the current sheet.
  property int generation: 0
  property int sentGeneration: 0
  property string previewRequested: ""

  implicitHeight: content.implicitHeight

  onQueryChanged: shown = Model.PAGE_ROWS

  function refresh() { tracker.send("spellings-list", []) }

  function send(command, args) {
    sentGeneration = generation
    return tracker.send(command, args)
  }

  function closeSheet() {
    generation++
    sheetKind = ""
    sheetError = ""
  }

  function openWord(pair) {
    sheetError = ""
    wordSheet.pair = pair
    generation++
    sheetKind = "word"
  }

  function openImport() {
    sheetError = ""
    importPreview = null
    importPath = ""
    previewRequested = ""
    generation++
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
      // Replies to a sheet that has since closed still refresh the list, but never write into the sheet that is open now.
      var current = root.sentGeneration === root.generation
      if (reply.error) {
        if (command === "spellings-list") root.listError = String(reply.error)
        else if (current) {
          root.sheetError = String(reply.error)
          if (command === "spellings-import-preview") root.importPreview = null
        }
        // A refused change usually means the file moved. Show the current list behind the sheet.
        if (command !== "spellings-list" && command !== "spellings-import-preview") root.refresh()
        return
      }
      if (command === "spellings-import-preview") {
        if (!current) return
        if (reply.problem === undefined && !reply.rows) { root.sheetError = "Mouthtype did not return a preview"; return }
        root.importPreview = reply
        root.importPath = root.previewRequested
        root.sheetError = ""
        return
      }
      if (!root.absorb(reply)) {
        if (command === "spellings-list") root.listError = "Mouthtype did not return the dictionary"
        else if (current) root.sheetError = "Mouthtype did not confirm the change"
        return
      }
      root.listError = ""
      if (command !== "spellings-list" && current) root.closeSheet()
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
      height: Math.max(toolbar.height, search.height)
      FieldBox {
        id: search
        visible: root.allGroups.length > 0
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(280, Math.max(120, parent.width - toolbar.width - 12))
        hint: root.library ? "Search " + root.library.count + (root.library.count === 1 ? " word" : " words") : "Search words"
        Accessible.name: "Search words"
        onTextChanged: root.query = text
      }
      Row {
        id: toolbar
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
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
      visible: root.library !== null && !root.library.problem && root.allGroups.length === 0
      width: parent.width
      DesignRow {
        title: "No saved spellings yet"
        detail: "Add a word Mouthtype keeps getting wrong, or import a CSV of names."
      }
    }

    DesignCard {
      visible: root.allGroups.length > 0 && root.groups.length === 0
      width: parent.width
      DesignRow {
        title: "No matches"
        detail: "No saved spelling matches \u201c" + root.query.trim() + "\u201d."
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
        model: root.shownGroups
        delegate: WordRow {
          required property var modelData
          group: modelData
          onEditRequested: function(pair) { root.openWord(pair) }
        }
      }

      ShowMoreRow {
        visible: root.groups.length > root.shown
        hidden: root.groups.length - root.shown
        batch: Model.PAGE_ROWS
        onActivated: root.shown += Model.PAGE_ROWS
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
      if (wordSheet.pair) root.send("spellings-edit", [wordSheet.pair.heard, heard, written, wordSheet.pair.written])
      else root.send("spellings-add", [heard, written])
    }
    onRemoveRequested: {
      root.sheetError = ""
      root.send("spellings-remove", [wordSheet.pair.heard, wordSheet.pair.written])
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
      root.previewRequested = path
      root.send("spellings-import-preview", [path])
    }
    onImportRequested: function(path, digest, csvDigest) {
      root.sheetError = ""
      root.send("spellings-import", [path, digest, csvDigest])
    }
  }
}
