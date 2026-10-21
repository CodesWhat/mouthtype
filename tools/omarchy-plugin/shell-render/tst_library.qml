import QtQuick
import QtTest
import ".."
import "../design"
import "../pages/library"
import "../pages/library/LibraryModel.js" as Model

// qmltestrunner scene for slice V5. Loads MouthtypeShell with a FixtureHost, answers the pages' requests from the JSON in
// pages/library/fixtures (real control_library.py output), drives the Dictionary and Transforms pages and their sheets, runs the
// mechanical text checks and saves PNGs to /tmp/mouthtype-shell/library-<scene>-<light|dark>.png.
// Run with QML_XHR_ALLOW_FILE_READ=1 so the fixtures can be read.
TestCase {
  id: tc

  name: "LibraryPages"
  when: windowShown
  visible: true
  width: 900
  height: 620

  FixtureHost { id: host; Component.onCompleted: { host.populated(); host.shellRef = shell } }

  MouthtypeShell {
    id: shell
    anchors.fill: parent
    host: host
  }

  property bool dark: false
  Binding { target: Theme; property: "forceDark"; value: tc.dark }

  property var requests: []
  property var handlers: ({})
  // Replies to hold back until a test releases them, keyed by verb.
  property var holds: ({})
  property var held: []

  Connections {
    target: shell
    function onPageRequested(command, args) {
      tc.requests.push([command, args])
      shell.pageBusy = true
      var handler = tc.handlers[command]
      // A fresh object per reply, like the shell's JSON.parse.
      var reply = copy(handler ? handler(args) : { error: "No handler for " + command })
      var deliver = function() { shell.pageResult(command, reply); shell.pageBusy = false }
      if (tc.holds[command]) tc.held.push(deliver)
      else Qt.callLater(deliver)
    }
  }

  function fixture(name) {
    var xhr = new XMLHttpRequest()
    xhr.open("GET", Qt.resolvedUrl("../pages/library/fixtures/" + name + ".json"), false)
    xhr.send()
    return JSON.parse(xhr.responseText)
  }

  function copy(value) { return JSON.parse(JSON.stringify(value)) }

  function statusFixture(state) {
    var reasons = {
      absent: "AI transforms need the Thorough cleanup model, and its files are missing. Run setup_cleanup.py --level thorough, then try again.",
      unconfigured: "AI transforms need the Thorough cleanup model. Set it up with setup_cleanup.py --level thorough, then try again."
    }
    var kinds = []
    for (var i = 0; i < Model.FALLBACK_KINDS.length; i++) {
      var kind = copy(Model.FALLBACK_KINDS[i])
      kind.available = !kind.needs_model || state === "ready"
      kind.reason = kind.needs_model && state !== "ready" ? reasons[state] : null
      kinds.push(kind)
    }
    return { state: "status", interface: 1, kinds: kinds, model: { level: "thorough", name: "Thorough", state: state, reason: reasons[state] || null },
             limits: { source_units: 16000, diff_characters: 20000, capture_seconds: 2 } }
  }

  function walk(item, predicate, found) {
    if (predicate(item)) found.push(item)
    for (var i = 0; i < item.children.length; i++) walk(item.children[i], predicate, found)
    return found
  }

  function texts() {
    return walk(shell, function(t) { return t.text !== undefined && t.font !== undefined && t.elide !== undefined && t.visible && t.width > 0 }, [])
  }

  function findText(label) {
    var all = texts()
    for (var i = 0; i < all.length; i++) if (all[i].text === label) return all[i]
    return null
  }

  function hasText(label) { return findText(label) !== null }

  function findAll(predicate) { return walk(shell, function(t) { return t.visible && predicate(t) }, []) }

  function field(hint) {
    var found = findAll(function(t) { return t.hint === hint && t.accepted !== undefined })
    return found.length ? found[0] : null
  }

  function button(label) {
    var found = findAll(function(t) { return t.primary !== undefined && t.text === label && t.activated !== undefined })
    return found.length ? found[0] : null
  }

  function page() {
    var found = walk(shell, function(t) { return t.backend !== undefined && t.request !== undefined }, [])
    return found.length ? found[0] : null
  }

  function checkText(label) {
    var all = texts()
    verify(all.length > 3, label + ": found " + all.length + " texts")
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      if (t.text === "") continue
      verify(t.font.pixelSize >= 10, label + ": below the floor: '" + t.text + "' " + t.font.pixelSize)
      compare(t.elide, Text.ElideNone, label + ": elide set on '" + t.text + "'")
      if (t.parent && t.parent.width > 0) verify(t.width <= t.parent.width + 0.5, label + ": overflows its parent: '" + t.text + "'")
    }
  }

  function begin(dark, handlerMap) {
    tc.dark = dark
    host.ran = []
    host.populated()
    shell.settingsOpen = false
    shell.shortcutOpen = false
    shell.navigate("home")
    shell.pageResults = ({})
    shell.pageError = ""
    shell.pageBusy = false
    requests = []
    holds = ({})
    held = []
    handlers = handlerMap
    wait(30)
  }

  function lists(spellings, phrases, status) {
    var map = {}
    map["spellings-list"] = function() { return fixture(spellings) }
    map["phrases-list"] = function() { return fixture(phrases) }
    map["transform-status"] = function() { return statusFixture(status) }
    return map
  }

  function openDictionary(handlerMap, dark) {
    begin(dark, handlerMap)
    shell.navigate("dictionary")
    tryVerify(function() { return page() !== null && page().library !== null }, 3000, "dictionary list never arrived")
    wait(60)
    return page()
  }

  function openTransforms(handlerMap, dark) {
    begin(dark, handlerMap)
    shell.navigate("transforms")
    tryVerify(function() { return page() !== null && page().status !== null }, 3000, "transform status never arrived")
    wait(60)
    return page()
  }

  function requested(command) {
    for (var i = 0; i < requests.length; i++) if (requests[i][0] === command) return requests[i][1]
    return null
  }

  function importWith(name, path) {
    var p = page()
    var reply = fixture(name)
    handlers["spellings-import-preview"] = function() { return reply }
    p.openImport()
    wait(60)
    var box = field("Path to a .csv file, for example ~/names.csv")
    verify(box !== null, "path field not found")
    box.text = path
    box.forceActiveFocus()
    keyClick(Qt.Key_Return)
    tryVerify(function() { return p.importPreview !== null }, 3000, "preview never arrived")
    wait(60)
  }

  // The page scrolls inside the shell's Flickable; show its end so the lower cards get rendered too.
  function scrollToEnd() {
    var found = walk(shell, function(t) { return t.contentY !== undefined && t.flickableDirection !== undefined && t.width > 500 }, [])
    verify(found.length > 0, "page Flickable")
    found[0].contentY = Math.max(0, found[0].contentHeight - found[0].height)
    wait(60)
  }

  property var saved: ({})

  function snap(name) {
    var key = "library-" + name + "-" + (tc.dark ? "dark" : "light")
    saved[key] = undefined
    shell.grabToImage(function(result) { saved[key] = result.saveToFile("/tmp/mouthtype-shell/" + key + ".png") })
    tryVerify(function() { return saved[key] !== undefined }, 3000, "grab never finished: " + key)
    verify(saved[key] === true, "could not save " + key)
  }

  readonly property var scenes: ["dictionary-list", "dictionary-empty", "dictionary-problem", "dictionary-restart", "dictionary-new-word", "dictionary-edit-word",
    "dictionary-word-error", "dictionary-import-start", "dictionary-import-valid", "dictionary-import-invalid", "dictionary-import-many",
    "dictionary-import-many-invalid", "dictionary-import-problem", "dictionary-long", "transforms-list", "transforms-bottom", "transforms-empty", "transforms-model-absent",
    "transforms-sheet-new", "transforms-sheet-edit-long", "transforms-sheet-clipboard", "transforms-sheet-error"]

  function test_render_data() {
    var rows = []
    for (var i = 0; i < scenes.length; i++) {
      rows.push({ tag: scenes[i] + " light", scene: scenes[i], dark: false })
      rows.push({ tag: scenes[i] + " dark", scene: scenes[i], dark: true })
    }
    return rows
  }

  function test_render(data) {
    var p
    switch (data.scene) {
      case "dictionary-list": openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); break
      case "dictionary-empty": openDictionary(lists("spellings-empty", "phrases-list", "ready"), data.dark); break
      case "dictionary-problem":
        var broken = copy(fixture("spellings-empty"))
        broken.problem = "The saved spellings could not be read: Invalid spelling entry. Fix dictionary.json and reload it."
        broken.writable = false
        var map = lists("spellings-empty", "phrases-list", "ready")
        map["spellings-list"] = function() { return broken }
        openDictionary(map, data.dark)
        break
      case "dictionary-restart":
        begin(data.dark, lists("spellings-list", "phrases-list", "ready"))
        var added = copy(fixture("spellings-list"))
        added.adopted_config = true
        shell.pageResult("spellings-add", added)
        shell.navigate("dictionary")
        tryVerify(function() { return page() !== null && page().library !== null }, 3000)
        wait(60)
        break
      case "dictionary-new-word": p = openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); p.openWord(null); wait(120); break
      case "dictionary-edit-word": p = openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); p.openWord(p.library.entries[2]); wait(120); break
      case "dictionary-word-error":
        p = openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark)
        p.openWord(null)
        p.sheetError = "A spelling for this heard phrase already exists."
        wait(120)
        break
      case "dictionary-import-start": p = openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); p.openImport(); wait(120); break
      case "dictionary-import-valid": openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); importWith("import-valid", "~/names.csv"); break
      case "dictionary-import-invalid": openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); importWith("import-invalid", "~/bad.csv"); break
      case "dictionary-import-many": openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); importWith("import-many", "~/many.csv"); break
      case "dictionary-import-many-invalid": openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); importWith("import-many-invalid", "~/many.csv"); break
      case "dictionary-import-problem": openDictionary(lists("spellings-list", "phrases-list", "ready"), data.dark); importWith("import-problem", "~/wrong.csv"); break
      case "dictionary-long":
        var longList = copy(fixture("spellings-list"))
        for (var n = 0; n < 40; n++) longList.entries.push({ heard: "name number " + n, written: "Name" + n, starred: n % 7 === 0, warning: null })
        longList.entries.push({ heard: "a very long heard phrase that somebody typed once and never trimmed back down to size", written: "Short", starred: false, warning: null })
        longList.count = longList.entries.length
        var bigMap = lists("spellings-list", "phrases-list", "ready")
        bigMap["spellings-list"] = function() { return longList }
        openDictionary(bigMap, data.dark)
        scrollToEnd()
        break
      case "transforms-list": openTransforms(lists("spellings-list", "phrases-list", "ready"), data.dark); break
      case "transforms-bottom": openTransforms(lists("spellings-list", "phrases-list", "ready"), data.dark); scrollToEnd(); break
      case "transforms-empty": openTransforms(lists("spellings-list", "phrases-empty", "ready"), data.dark); break
      case "transforms-model-absent": openTransforms(lists("spellings-list", "phrases-list", "absent"), data.dark); scrollToEnd(); break
      case "transforms-sheet-new": p = openTransforms(lists("spellings-list", "phrases-list", "ready"), data.dark); p.openSheet(null); wait(120); break
      case "transforms-sheet-edit-long": p = openTransforms(lists("spellings-list", "phrases-list", "ready"), data.dark); p.openSheet(p.entries[6]); wait(120); break
      case "transforms-sheet-clipboard": p = openTransforms(lists("spellings-list", "phrases-list", "ready"), data.dark); p.openSheet(p.entries[3]); wait(120); break
      case "transforms-sheet-error":
        p = openTransforms(lists("spellings-list", "phrases-list", "ready"), data.dark)
        p.openSheet(null)
        p.sheetError = "A phrase with this trigger already exists."
        wait(120)
        break
    }
    checkText(data.tag)
    snap(data.scene)
  }

  // -- Dictionary behaviour

  function test_dictionary_groups_and_marks() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    compare(p.groups.length, 9, "twelve pairs group into nine written forms")
    verify(hasText("Priya"))
    verify(hasText("★"), "a starred entry shows its star")
    verify(findText("‘win’ is an everyday word, so every ‘win’ you say becomes Winn.") !== null, "the everyday-word warning is on the list")
    compare(requested("spellings-list"), [])
  }

  function test_empty_state() {
    openDictionary(lists("spellings-empty", "phrases-list", "ready"), false)
    verify(hasText("No saved spellings yet"))
  }

  function test_new_word_saves_with_ctrl_return() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    var after = copy(fixture("spellings-list"))
    after.entries.push({ heard: "sean", written: "Sean", starred: false, warning: null })
    after.count = after.entries.length
    handlers["spellings-add"] = function() { return after }
    p.openWord(null)
    wait(120)
    verify(p.editing, "an open sheet marks the page as editing so the panel keeps Esc")
    var written = field("Sean")
    var heard = field("shawn")
    verify(written !== null && heard !== null, "word fields")
    written.text = "Sean"
    heard.text = "  sean "
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return p.sheetKind === "" }, 3000, "sheet did not close after saving")
    compare(requested("spellings-add"), ["sean", "Sean"])
    compare(p.library.count, 13)
  }

  function test_escape_cancels_without_a_request() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    p.openWord(null)
    wait(120)
    field("Sean").text = "Typed"
    keyClick(Qt.Key_Escape)
    tryVerify(function() { return p.sheetKind === "" }, 2000)
    compare(requested("spellings-add"), null)
    verify(!p.editing)
  }

  function test_save_is_disabled_until_both_fields_are_filled() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    p.openWord(null)
    wait(120)
    verify(!button("Save").enabled)
    field("Sean").text = "Sean"
    verify(!button("Save").enabled)
    field("shawn").text = "shawn"
    verify(button("Save").enabled)
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    wait(100)
    verify(requested("spellings-add") !== null)
  }

  function test_edit_sends_the_saved_written_form_as_the_expect_value() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    var pair = p.library.entries[2]
    handlers["spellings-edit"] = function() { return fixture("spellings-list") }
    p.openWord(pair)
    wait(120)
    compare(field("Sean").text, pair.written)
    field("Sean").text = "MouthType"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return p.sheetKind === "" }, 3000)
    compare(requested("spellings-edit"), [pair.heard, pair.heard, "MouthType", pair.written])
  }

  function test_remove_needs_a_second_click_and_sends_the_expect_value() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    var pair = p.library.entries[4]
    handlers["spellings-remove"] = function() { return fixture("spellings-list") }
    p.openWord(pair)
    wait(120)
    mouseClick(button("Remove"))
    wait(60)
    compare(requested("spellings-remove"), null)
    mouseClick(button("Click again to remove"))
    tryVerify(function() { return p.sheetKind === "" }, 3000)
    compare(requested("spellings-remove"), [pair.heard, pair.written])
  }

  function test_a_refused_change_keeps_the_sheet_shows_the_error_and_reloads() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    var pair = p.library.entries[0]
    handlers["spellings-edit"] = function() { return { error: "This spelling changed outside the editor. Close this sheet and try again." } }
    p.openWord(pair)
    wait(120)
    field("Sean").text = "Priyaa"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return p.sheetError !== "" }, 3000)
    compare(p.sheetKind, "word")
    verify(hasText("This spelling changed outside the editor. Close this sheet and try again."))
    tryVerify(function() {
      var n = 0
      for (var i = 0; i < requests.length; i++) if (requests[i][0] === "spellings-list") n++
      return n > 1
    }, 3000, "the list was not reloaded after a refused change")
  }

  function test_adopted_config_shows_the_restart_note() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    verify(!hasText("Restart Mouthtype to use this dictionary"))
    var after = copy(fixture("spellings-list"))
    after.adopted_config = true
    handlers["spellings-add"] = function() { return after }
    p.openWord(null)
    wait(120)
    field("Sean").text = "Sean"
    field("shawn").text = "shawn"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return hasText("Restart Mouthtype to use this dictionary") }, 3000)
  }

  // -- Import CSV sheet

  function test_import_valid_passes_both_digests() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    importWith("import-valid", "~/names.csv")
    var preview = fixture("import-valid")
    verify(hasText("Import 3 spellings"))
    verify(button("Import 3 spellings").enabled)
    handlers["spellings-import"] = function() { return fixture("spellings-list") }
    mouseClick(button("Import 3 spellings"))
    tryVerify(function() { return p.sheetKind === "" }, 3000)
    compare(requested("spellings-import"), ["~/names.csv", preview.digest, preview.csv_digest])
  }

  function test_import_is_off_while_a_row_is_invalid() {
    openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    importWith("import-invalid", "~/bad.csv")
    verify(!button("Import 5 spellings").enabled)
    verify(findText("Nothing changes until you import. Fix the errors in the file, then choose it again.") !== null, "the footnote names the reason")
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    wait(100)
    compare(requested("spellings-import"), null)
    verify(hasText("Blank"), "a blank heard column reads Blank")
  }

  function test_import_shows_first_six_plus_every_invalid_row() {
    openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    importWith("import-many-invalid", "~/many.csv")
    verify(hasText("… and 13 more rows"), "21 rows, 6 shown, 2 invalid among them later: 21 - 6 - 2 = 13")
    var rows = Model.visibleImportRows(fixture("import-many-invalid").rows)
    compare(rows.shown.length, 8)
    compare(rows.hidden, 13)
  }

  function test_import_changed_path_disables_the_stale_preview() {
    openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    importWith("import-valid", "~/names.csv")
    verify(button("Import 3 spellings").enabled)
    field("Path to a .csv file, for example ~/names.csv").text = "~/other.csv"
    wait(60)
    verify(!button("Import 3 spellings").enabled, "a preview for another path cannot be imported")
  }

  // -- Transforms behaviour

  function test_transform_rows_tags_and_one_line_clip() {
    var p = openTransforms(lists("spellings-list", "phrases-list", "ready"), false)
    verify(hasText("my work email"))
    verify(hasText("TEXT"))
    verify(hasText("2 LINES"))
    verify(hasText("CLIPBOARD"))
    verify(hasText("DATE"))
    var clipped = findAll(function(t) { return t.overflowing !== undefined && t.naturalWidth !== undefined })
    verify(clipped.length >= 7, "every phrase row has a one-line clip")
    var fading = 0
    for (var i = 0; i < clipped.length; i++) {
      if (clipped[i].overflowing) fading++
      verify(clipped[i].height < 24, "a phrase stays on one line")
    }
    verify(fading >= 2, "the long link and the long phrase clip with a fade")
    var all = texts()
    for (var j = 0; j < all.length; j++) verify(all[j].text.indexOf("…") < 0, "no ellipsis in '" + all[j].text + "'")
  }

  function test_transform_model_status() {
    openTransforms(lists("spellings-list", "phrases-list", "ready"), false)
    verify(hasText("NO MODEL · INSTANT"))
    verify(hasText("THOROUGH · READY"))
    openTransforms(lists("spellings-list", "phrases-list", "absent"), false)
    verify(hasText("THOROUGH · NOT PREPARED"))
  }

  function test_new_transform_inserts_variables_and_saves() {
    var p = openTransforms(lists("spellings-list", "phrases-list", "ready"), false)
    var after = copy(fixture("phrases-list"))
    handlers["phrases-add"] = function() { return after }
    p.openSheet(null)
    wait(120)
    field("my work email").text = "today"
    var area = findAll(function(t) { return t.area !== undefined && t.insertText !== undefined })[0]
    verify(area !== undefined, "text area")
    area.area.text = "Date: "
    area.area.cursorPosition = 6
    mouseClick(button("+ Date"))
    compare(area.area.text, "Date: {date}")
    mouseClick(button("+ Clipboard"))
    compare(area.area.text, "Date: {date}{clipboard}")
    verify(hasText("{date} becomes today’s date; {clipboard} becomes whatever you copied before dictating."))
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return !p.sheetOpen }, 3000)
    compare(requested("phrases-add"), ["today", "Date: {date}{clipboard}"])
  }

  function test_phrase_edit_and_remove_send_the_expect_value() {
    var p = openTransforms(lists("spellings-list", "phrases-list", "ready"), false)
    var entry = p.entries[1]
    handlers["phrases-edit"] = function() { return fixture("phrases-list") }
    handlers["phrases-remove"] = function() { return fixture("phrases-list") }
    p.openSheet(entry)
    wait(120)
    field("my work email").text = "closing"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return !p.sheetOpen }, 3000)
    compare(requested("phrases-edit"), [entry.trigger, "closing", entry.expansion, entry.expansion])
    p.openSheet(entry)
    wait(120)
    mouseClick(button("Remove"))
    mouseClick(button("Click again to remove"))
    tryVerify(function() { return !p.sheetOpen }, 3000)
    compare(requested("phrases-remove"), [entry.trigger, entry.expansion])
  }

  function test_transform_restart_note_and_escape() {
    var p = openTransforms(lists("spellings-list", "phrases-list", "ready"), false)
    var after = copy(fixture("phrases-list"))
    after.adopted_config = true
    handlers["phrases-add"] = function() { return after }
    p.openSheet(null)
    wait(120)
    field("my work email").text = "a"
    findAll(function(t) { return t.area !== undefined && t.insertText !== undefined })[0].area.text = "b"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return hasText("Restart Mouthtype to use these transforms") }, 3000)
    p.openSheet(null)
    wait(120)
    keyClick(Qt.Key_Escape)
    tryVerify(function() { return !p.sheetOpen }, 2000)
  }

  // -- Request tracking and stale replies

  RequestTracker { id: probe }

  function probeState(busy, results, error) { probe.backend = { busy: busy, results: results, error: error || "", state: {}, dark: false } }

  function test_tracker_finishes_a_null_reply_with_an_error() {
    var done = []
    var hook = function(command, reply) { done.push([command, reply]) }
    probe.finished.connect(hook)
    probeState(false, {})
    probe.send("x", [])
    probeState(true, {})
    probeState(false, { x: null })
    wait(50)
    probe.finished.disconnect(hook)
    compare(done.length, 1)
    compare(done[0][1].error, "Mouthtype did not answer")
    verify(!probe.waiting)
  }

  function test_tracker_skips_the_request_queued_ahead_of_it() {
    var done = []
    var hook = function(command, reply) { done.push([command, reply]) }
    probe.finished.connect(hook)
    probeState(true, {})
    probe.send("x", [])
    probeState(false, {}, "the earlier request failed")
    compare(done.length, 0, "the first falling edge belongs to the earlier request")
    probeState(true, {})
    var mine = { ok: 1 }
    probeState(false, { x: mine }, "")
    wait(50)
    probe.finished.disconnect(hook)
    compare(done.length, 1)
    verify(done[0][1] === mine || done[0][1].ok === 1, "our own reply, not the earlier error")
    verify(!done[0][1].error)
  }

  function test_tracker_reports_a_shell_error_when_no_reply_arrives() {
    var done = []
    var hook = function(command, reply) { done.push([command, reply]) }
    probe.finished.connect(hook)
    probeState(false, {})
    probe.send("x", [])
    probeState(true, {})
    probeState(false, {}, "Mouthtype page request failed")
    wait(50)
    probe.finished.disconnect(hook)
    compare(done.length, 1)
    compare(done[0][1].error, "Mouthtype page request failed")
  }

  function test_a_late_reply_does_not_close_or_fill_a_newer_sheet() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    holds["spellings-add"] = true
    var after = copy(fixture("spellings-list"))
    handlers["spellings-add"] = function() { return after }
    p.openWord(null)
    wait(120)
    field("Sean").text = "Sean"
    field("shawn").text = "shawn"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return held.length === 1 }, 3000)
    keyClick(Qt.Key_Escape)
    tryVerify(function() { return p.sheetKind === "" }, 2000)
    p.openWord(null)
    wait(120)
    field("Sean").text = "Second"
    held[0]()
    wait(200)
    compare(p.sheetKind, "word", "the newer sheet stays open")
    compare(field("Sean").text, "Second", "and keeps what was typed")
    compare(p.sheetError, "")
  }

  function test_a_late_error_does_not_land_on_a_newer_sheet() {
    var p = openTransforms(lists("spellings-list", "phrases-list", "ready"), false)
    holds["phrases-add"] = true
    handlers["phrases-add"] = function() { return { error: "A phrase with this trigger already exists." } }
    p.openSheet(null)
    wait(120)
    field("my work email").text = "a"
    findAll(function(t) { return t.area !== undefined && t.insertText !== undefined })[0].area.text = "b"
    keyClick(Qt.Key_Return, Qt.ControlModifier)
    tryVerify(function() { return held.length === 1 }, 3000)
    keyClick(Qt.Key_Escape)
    tryVerify(function() { return !p.sheetOpen }, 2000)
    p.openSheet(null)
    wait(120)
    held[0]()
    wait(200)
    verify(p.sheetOpen)
    compare(p.sheetError, "")
  }

  function test_a_preview_reply_is_tied_to_the_path_that_was_requested() {
    var p = openDictionary(lists("spellings-list", "phrases-list", "ready"), false)
    var reply = fixture("import-valid")
    handlers["spellings-import-preview"] = function() { return reply }
    holds["spellings-import-preview"] = true
    p.openImport()
    wait(120)
    var box = field("Path to a .csv file, for example ~/names.csv")
    box.text = "~/a.csv"
    box.forceActiveFocus()
    keyClick(Qt.Key_Return)
    tryVerify(function() { return held.length === 1 }, 3000)
    box.text = "~/b.csv"
    held[0]()
    tryVerify(function() { return p.importPreview !== null }, 3000)
    compare(p.importPath, "~/a.csv")
    wait(60)
    verify(!button("Import 3 spellings").enabled, "a preview for ~/a.csv cannot import ~/b.csv")
  }
}
