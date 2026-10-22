import QtQuick
import QtTest
import ".."
import "../design"
import "../pages/style/fixtures/StyleFixtures.js" as Fixtures

// qmltestrunner scene for slice V3. Loads MouthtypeShell with a FixtureHost, walks every page and the Settings modal in light
// and dark, runs the mechanical text checks, checks the page contract, and saves PNGs to /tmp/mouthtype-shell/.
TestCase {
  id: tc

  name: "MouthtypeShell"
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

  // Under the Style page while it is grabbed whole, so the PNG has the window colour instead of black.
  Component { id: backdrop; Rectangle { anchors.fill: parent; z: -1; color: Theme.bg } }

  property bool dark: false
  Binding { target: Theme; property: "forceDark"; value: tc.dark }

  function walk(item, found) {
    if (item.text !== undefined && item.font !== undefined && item.elide !== undefined && item.visible) found.push(item)
    for (var i = 0; i < item.children.length; i++) walk(item.children[i], found)
    return found
  }

  function visibleTexts() {
    var all = walk(shell, [])
    var out = []
    for (var i = 0; i < all.length; i++) {
      // Skip text inside a hidden ancestor: Item.visible is the effective visibility already.
      if (all[i].width > 0) out.push(all[i])
    }
    return out
  }

  function checkText(label) {
    var texts = visibleTexts()
    verify(texts.length > 3, label + ": found " + texts.length + " texts")
    for (var i = 0; i < texts.length; i++) {
      var t = texts[i]
      if (t.text === "") continue
      verify(t.font.pixelSize >= 10, label + ": below the floor: '" + t.text + "' " + t.font.pixelSize)
      compare(t.elide, Text.ElideNone, label + ": elide set on '" + t.text + "'")
      if (t.parent && t.parent.width > 0) verify(t.width <= t.parent.width + 0.5, label + ": overflows its parent: '" + t.text + "'")
    }
  }

  function setScene(scene) {
    host.ran = []
    shell.pageResults = ({})
    host.fileImport = { state: "off" }
    host.importText = ""
    host.populated()
    shell.advancedOptions = false
    shell.settingsOpen = false
    shell.shortcutOpen = false
    shell.settingsTab = "general"
    shell.navigate("home")
    switch (scene) {
      case "home-empty": host.empty(); shell.navigate("home"); break
      case "home-welcome": host.config = Object.assign({}, host.config, { delivery_mode: "recover" }); shell.navigate("home"); break
      case "home-welcomed": host.config = Object.assign({}, host.config, { delivery_mode: "recover" }); host.welcomed = true; shell.navigate("home"); break
      case "stats": shell.navigate("stats"); break
      case "dictionary": shell.navigate("dictionary"); break
      case "transforms": shell.navigate("transforms"); break
      case "style": shell.navigate("style"); break
      case "style-personal": openStyle("personal", Fixtures.populated); break
      case "style-work": openStyle("work", Fixtures.populated); break
      case "style-email": openStyle("email", Fixtures.populated); break
      case "style-other": openStyle("other", Fixtures.populated); break
      case "style-cleanup": openStyle("cleanup", Fixtures.populated); break
      case "style-fresh": openStyle("personal", Fixtures.fresh); break
      case "style-fresh-cleanup": host.empty(); openStyle("cleanup", Fixtures.fresh); break
      case "style-error":
        openStyle("work", Fixtures.populated)
        shell.pageResult("style-add-app", { error: "App must be one exact window class of up to 128 characters, without wildcards" })
        break
      case "appearance": shell.navigate("appearance"); break
      case "appearance-hifi": host.pillPrefs = { enabled: true, skin: "hifi", size: 2 }; shell.navigate("appearance"); break
      case "transcript": shell.navigate("transcript"); break
      case "import-active": host.fileImport = { state: "transcribing", format: "m4a", id: "x" }; shell.navigate("import"); break
      case "import-done":
        host.fileImport = { state: "finished", format: "m4a", id: "x", duration_seconds: 83 }
        host.importText = "This is the raw recognition of the file. Nothing is cleaned up, so it keeps its own punctuation and every um. The card scrolls when the text runs long. " +
          "A second sentence makes the card taller so the wrap is visible in the render, and a third keeps it honest about long transcripts."
        host.importTextFor = "x"
        shell.navigate("import")
        break
      case "import-failed": host.fileImport = { state: "failed", format: "wav", id: "x", message: "The file could not be decoded." }; shell.navigate("import"); break
      case "settings-general": shell.navigate("general"); break
      case "settings-general-off": host.empty(); shell.navigate("general"); break
      case "settings-linux": shell.navigate("linux"); break
      case "settings-health": shell.navigate("health"); break
      case "settings-health-empty": host.empty(); shell.navigate("health"); break
      case "settings-advanced": shell.navigate("advanced"); break
      case "shortcut": shell.navigate("shortcut"); break
      case "error": host.errorText = "Mouthtype could not start the service."; shell.navigate("home"); break
      default: shell.navigate("home")
    }
    wait(250)
  }

  function stylePage() {
    var page = null
    function find(item) {
      if (item.editError !== undefined && item.request !== undefined) { page = item; return }
      for (var i = 0; i < item.children.length && !page; i++) find(item.children[i])
    }
    find(shell)
    return page
  }

  function openStyle(tab, state) {
    host.lastState = { config: host.config, cleanup: host.cleanupInfo }
    shell.navigate("style")
    tryVerify(function() { return stylePage() !== null }, 2000)
    var page = stylePage()
    page.tab = tab
    shell.pageResult("style-state", JSON.parse(JSON.stringify(state)))
    tryVerify(function() { return page.styles !== null }, 2000)
    return page
  }

  property var saved: ({})
  readonly property var scenes: ["home", "home-empty", "home-welcome", "home-welcomed", "stats", "dictionary", "transforms", "style", "style-personal", "style-work",
    "style-email", "style-other", "style-cleanup", "style-fresh", "style-fresh-cleanup", "style-error", "appearance", "appearance-hifi",
    "transcript", "import-active", "import-done", "import-failed", "settings-general", "settings-general-off", "settings-linux",
    "settings-health", "settings-health-empty", "settings-advanced", "shortcut", "error"]

  function test_render_data() {
    var rows = []
    for (var i = 0; i < scenes.length; i++) {
      rows.push({ tag: scenes[i] + " light", scene: scenes[i], dark: false })
      rows.push({ tag: scenes[i] + " dark", scene: scenes[i], dark: true })
    }
    return rows
  }

  function test_render(data) {
    tc.dark = data.dark
    setScene(data.scene)
    checkText(data.tag)
    var key = data.scene + "-" + (data.dark ? "dark" : "light")
    saved[key] = undefined
    shell.grabToImage(function(result) { saved[key] = result.saveToFile("/tmp/mouthtype-shell/" + key + ".png") })
    tryVerify(function() { return saved[key] !== undefined }, 3000, "grab never finished: " + key)
    verify(saved[key] === true, "could not save " + key)
    // The Style page is taller than the window, so it is also saved whole.
    if (data.scene.indexOf("style-") === 0 && stylePage() !== null) {
      var whole = key + "-page"
      saved[whole] = undefined
      var back = backdrop.createObject(stylePage())
      stylePage().grabToImage(function(result) { saved[whole] = result.saveToFile("/tmp/mouthtype-shell/" + whole + ".png") })
      tryVerify(function() { return saved[whole] !== undefined }, 3000, "grab never finished: " + whole)
      back.destroy()
      verify(saved[whole] === true, "could not save " + whole)
    }
  }

  function test_nav_pages() {
    tc.dark = false
    setScene("home")
    compare(shell.page, "home")
    shell.navigate("dictionary")
    compare(shell.page, "dictionary")
    tryVerify(function() { return pageTitle() === "Your names, spelled right." }, 2000)
    shell.navigate("stats")
    tryVerify(function() { return pageTitle() === "Stats" }, 2000)
    shell.navigate("transforms")
    tryVerify(function() { return pageTitle() === "Say this, get that." }, 2000)
    shell.navigate("style")
    tryVerify(function() { return pageTitle() === "Style" }, 2000)
  }

  function pageTitle() {
    var texts = walk(shell, [])
    for (var i = 0; i < texts.length; i++) if (texts[i].font.pixelSize === 28) return texts[i].text
    return ""
  }

  function test_old_page_names() {
    setScene("home")
    shell.navigate("pill"); compare(shell.page, "appearance")
    shell.navigate("fonts"); compare(shell.page, "appearance")
    shell.navigate("menu"); compare(shell.page, "home"); verify(!shell.settingsOpen)
    shell.navigate("cleanup"); verify(shell.settingsOpen); compare(shell.settingsTab, "health")
    shell.navigate("shortcut"); verify(shell.shortcutOpen)
    verify(shell.dismissLayer()); verify(!shell.shortcutOpen); verify(shell.settingsOpen)
    verify(shell.dismissLayer()); verify(!shell.settingsOpen)
    verify(!shell.dismissLayer())
    shell.navigate("nonsense"); compare(shell.page, "home")
  }

  function test_data_page_contract() {
    setScene("dictionary")
    tryVerify(function() { return pageTitle() === "Your names, spelled right." }, 2000)
    var requests = []
    shell.pageRequested.connect(function(command, args) { requests.push([command, args]) })
    var page = null
    function find(item) {
      if (item.backend !== undefined && item.request !== undefined) { page = item; return }
      for (var i = 0; i < item.children.length && !page; i++) find(item.children[i])
    }
    find(shell)
    verify(page !== null, "page with backend and request not found")
    verify(page.backend.results !== undefined, "backend.results missing")
    verify(page.backend.state !== undefined, "backend.state missing")
    compare(page.backend.busy, false)
    page.request("spellings", ["list"])
    compare(requests.length, 1)
    compare(requests[0][0], "spellings")
    shell.pageResult("spellings", { entries: [1, 2] })
    compare(page.backend.results.spellings.entries.length, 2)
    compare(page.backend.error, "")
    shell.pageResult("spellings", { error: "nope" })
    compare(page.backend.error, "nope")
  }

  function findByName(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findByName(item.children[i], name)
      if (found) return found
    }
    return null
  }

  function findText(label) {
    var texts = walk(shell, [])
    for (var i = 0; i < texts.length; i++) if (texts[i].text === label && texts[i].width > 0) return texts[i]
    return null
  }

  function test_sidebar_click_navigates() {
    tc.dark = false
    setScene("home")
    var row = findText("Dictionary")
    verify(row !== null, "Dictionary row not found")
    mouseClick(row)
    compare(shell.page, "dictionary")
    mouseClick(findText("Settings"))
    verify(shell.settingsOpen)
  }

  function test_home_buttons_send_verbs() {
    tc.dark = false
    setScene("home")
    mouseClick(findText("Start Dictation"))
    compare(host.ran.length, 1)
    compare(host.ran[0][0], "start")
    host.ran = []
    mouseClick(findText("Copy Last"))
    compare(host.ran[0][0], "copy")
  }

  function test_welcome_card() {
    tc.dark = false
    setScene("home-welcome")
    verify(findText("Where should your words go?") !== null, "card missing while recover and not welcomed")
    verify(findText("Dictate from anywhere") !== null, "shortcut row missing")
    setScene("home-welcomed")
    compare(findText("Where should your words go?"), null)
    setScene("home")
    compare(findText("Where should your words go?"), null)
    setScene("home-welcome")
    mouseClick(findText("Just save them"))
    compare(host.ran[0], ["set-plugin", "welcomed", "on"])
    host.ran = []
    mouseClick(findText("Paste where I'm typing (Recommended)"))
    compare(host.ran[0], ["set-config", "delivery", "paste"])
  }

  function findSwitch(label, item) {
    if (item.toggle !== undefined && item.text === label) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findSwitch(label, item.children[i])
      if (found) return found
    }
    return null
  }

  function test_settings_switch_sends_verb() {
    tc.dark = false
    setScene("settings-linux")
    host.ran = []
    var sw = findSwitch("Launch at login", shell)
    verify(sw !== null, "switch not found")
    mouseClick(sw)
    compare(host.ran.length, 1)
    compare(host.ran[0][0], "set-autostart")
    compare(host.ran[0][1], "off")
  }

  // ---- Style page (slice V6) ----------------------------------------------------------------------------------------------

  function collect(item, key, found) {
    if (item[key] !== undefined && item.visible) found.push(item)
    for (var i = 0; i < item.children.length; i++) collect(item.children[i], key, found)
    return found
  }

  function allTexts() {
    var out = []
    var texts = walk(shell, [])
    for (var i = 0; i < texts.length; i++) if (texts[i].width > 0) out.push(String(texts[i].text))
    return out
  }

  function test_style_tone_cards_show_added_characters() {
    tc.dark = false
    var tabs = ["personal", "work", "email", "other"]
    for (var t = 0; t < tabs.length; t++) {
      setScene("home")
      var page = openStyle(tabs[t], Fixtures.populated)
      wait(150)
      var marked = collect(shell, "markWidths", [])
      var expected = 0
      var context = page.contextById(tabs[t])
      for (var s = 0; s < context.samples.length; s++) expected += context.samples[s].lines.length
      compare(marked.length, expected, tabs[t] + ": one marked line per sample line")
      var withMarks = 0
      for (var m = 0; m < marked.length; m++) {
        var line = marked[m]
        compare(line.markWidths.length, line.markRanges.length)
        for (var w = 0; w < line.markWidths.length; w++) verify(line.markWidths[w] > 0, tabs[t] + ": mark has no width in '" + line.styled + "'")
        if (line.markRanges.length > 0) {
          withMarks++
          verify(!Qt.colorEqual(line.tint, Theme.surface), "tint matches the surface")
          verify(!Qt.colorEqual(line.tint, line.boxColor), "tint matches the box")
        }
      }
      verify(withMarks > 0, tabs[t] + ": no tone added anything to any sample")
    }
  }

  function test_style_marks_in_dark() {
    tc.dark = true
    setScene("style-personal")
    wait(150)
    var marked = collect(shell, "markWidths", [])
    verify(marked.length > 0)
    for (var m = 0; m < marked.length; m++) {
      for (var w = 0; w < marked[m].markWidths.length; w++) verify(marked[m].markWidths[w] > 0)
      if (marked[m].markRanges.length > 0) verify(!Qt.colorEqual(marked[m].tint, Theme.bg))
    }
    tc.dark = false
  }

  function test_style_tabs_and_no_websites() {
    tc.dark = false
    setScene("style-personal")
    var seenTitles = allTexts()
    var wanted = ["Personal messages", "Work messages", "Email", "Other", "Cleanup"]
    for (var i = 0; i < wanted.length; i++) verify(seenTitles.indexOf(wanted[i]) >= 0, "tab missing: " + wanted[i])
    var tabs = ["personal", "work", "email", "other", "cleanup"]
    for (var t = 0; t < tabs.length; t++) {
      stylePage().tab = tabs[t]
      wait(100)
      var joined = allTexts().join("\n").toLowerCase()
      verify(joined.indexOf("website") < 0, tabs[t] + ": mentions websites")
      verify(joined.indexOf("globe") < 0, tabs[t] + ": mentions a globe")
    }
    stylePage().tab = "personal"
    wait(100)
    mouseClick(findText("Email"))
    compare(stylePage().tab, "email")
    mouseClick(findText("Cleanup"))
    compare(stylePage().tab, "cleanup")
  }

  function test_style_members_and_tags() {
    tc.dark = false
    setScene("style-personal")
    var texts = allTexts()
    verify(texts.indexOf("Signal") >= 0)
    verify(texts.indexOf("Telegram") >= 0)
    verify(texts.indexOf("Chat") >= 0, "added app missing")
    verify(texts.indexOf("Discord") < 0, "a removed built-in is still listed")
    var builtIn = 0, added = 0
    for (var i = 0; i < texts.length; i++) {
      if (texts[i] === "BUILT IN") builtIn++
      if (texts[i] === "ADDED BY YOU") added++
    }
    compare(builtIn, 2)
    compare(added, 1)
    verify(texts.indexOf("Cleanup here") >= 0)
    verify(texts.indexOf("Same as everywhere · Fast") >= 0, "cleanup-here popup label")
    var memberTones = 0
    for (var j = 0; j < texts.length; j++) if (texts[j] === "Same as personal · Casual") memberTones++
    compare(memberTones, 3, "each member offers 'Same as <context>' for tone")
  }

  function test_style_tone_card_click_sends_verb() {
    tc.dark = false
    setScene("style-personal")
    var requests = []
    shell.pageRequested.connect(function(command, args) { requests.push([command, args]) })
    mouseClick(findText("Very casual"))
    compare(requests.length, 1)
    compare(requests[0][0], "style-set-tone")
    compare(requests[0][1][0], "personal")
    compare(requests[0][1][1], "very_casual")
  }

  function test_style_suggested_tone_hint() {
    tc.dark = false
    setScene("style-fresh")
    var hint = ""
    var texts = allTexts()
    for (var i = 0; i < texts.length; i++) if (texts[i].indexOf("No tone is set") === 0) hint = texts[i]
    verify(hint.indexOf("Suggested: Casual") >= 0, "hint: " + hint)
    var requests = []
    shell.pageRequested.connect(function(command, args) { requests.push([command, args]) })
    mouseClick(findText("Use Casual"))
    compare(requests.length, 1)
    compare(requests[0][0], "style-set-tone")
    compare(requests[0][1][1], "casual")
    stylePage().tab = "other"
    wait(100)
    verify(findText("Use Casual") === null, "Other has no suggestion")
    // A context with a tone set offers to clear it instead.
    setScene("style-personal")
    verify(findText("Clear the tone") !== null)
    verify(findText("Use Casual") === null)
  }

  function findField(item) {
    if (item.hint !== undefined && item.text !== undefined && item.accepted !== undefined) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findField(item.children[i])
      if (found) return found
    }
    return null
  }

  function test_style_add_app_row() {
    tc.dark = false
    setScene("style-work")
    var requests = []
    shell.pageRequested.connect(function(command, args) { requests.push([command, args]) })
    mouseClick(findText("Add an app"))
    var field = findField(shell)
    verify(field !== null && field.visible, "window class field")
    verify(findText("Window class, e.g. org.telegram.desktop") !== null)
    var joined = allTexts().join("\n")
    verify(joined.indexOf("hyprctl clients") >= 0, "hint about hyprctl clients")
    field.text = "bad*class"
    mouseClick(findText("Add"))
    compare(requests.length, 0)
    verify(allTexts().join("\n").indexOf("without wildcards") >= 0, "wildcard problem shown")
    field.text = "org.example.Notes"
    mouseClick(findText("Add"))
    compare(requests.length, 1)
    compare(requests[0][0], "style-add-app")
    compare(requests[0][1][0], "work")
    compare(requests[0][1][1], "org.example.Notes")
    verify(findField(shell) === null || !findField(shell).visible, "editor closes after adding")
  }

  function test_style_cleanup_tab() {
    tc.dark = false
    setScene("style-cleanup")
    var texts = allTexts()
    var wanted = ["Off", "Basic", "Fast", "Thorough"]
    for (var i = 0; i < wanted.length; i++) verify(texts.indexOf(wanted[i]) >= 0, "level missing: " + wanted[i])
    var requests = []
    shell.pageRequested.connect(function(command, args) { requests.push([command, args]) })
    mouseClick(findText("Basic"))
    compare(requests.length, 1)
    compare(requests[0][0], "set-config")
    compare(requests[0][1][0], "cleanup")
    compare(requests[0][1][1], "basic")
    // Thorough has no prepared model in the fixture, so its card does nothing and offers Prepare instead.
    mouseClick(findText("Thorough"))
    compare(requests.length, 1)
    mouseClick(findText("Prepare…"))
    compare(requests.length, 2)
    compare(requests[1][0], "cleanup-setup")
    compare(requests[1][1][0], "thorough")
    // Where it's different lists the overrides with a way to the tab.
    mouseClick(findText("Change on its tab"))
    verify(stylePage().tab === "work" || stylePage().tab === "other")
  }

  function test_style_replies_update_the_page() {
    tc.dark = false
    setScene("style-personal")
    var page = stylePage()
    var edited = JSON.parse(JSON.stringify(Fixtures.populated))
    edited.contexts[0].tone = "formal"
    shell.pageResult("style-set-tone", edited)
    compare(page.styles.contexts[0].tone, "formal")
    shell.pageResult("style-add-app", { error: "That app is not in this context" })
    compare(page.editError, "That app is not in this context")
    compare(page.styles.contexts[0].tone, "formal", "an error keeps the last good state")
    shell.pageResult("style-state", JSON.parse(JSON.stringify(Fixtures.populated)))
    compare(page.editError, "")
  }

  function test_style_requests_state_when_shown() {
    tc.dark = false
    setScene("home")
    var requests = []
    shell.pageRequested.connect(function(command, args) { requests.push([command, args]) })
    shell.navigate("style")
    tryVerify(function() { return requests.length > 0 }, 2000)
    compare(requests[0][0], "style-state")
    verify(allTexts().join("\n").indexOf("Reading your Style settings") >= 0)
  }

  function test_health_shows_download_bytes_and_bar() {
    tc.dark = false
    setScene("settings-health-empty")
    verify(allTexts().indexOf("1000 MB of 2497 MB") >= 0, "bytes done of total while downloading")
    var bar = findByName(shell, "setupProgress")
    verify(bar !== null && bar.visible, "determinate bar is shown")
    fuzzyCompare(bar.value, 1000000000 / 2497281120, 0.001)
  }

  function test_health_points_to_style() {
    tc.dark = false
    setScene("settings-health")
    var texts = allTexts()
    verify(texts.indexOf("Open Style") >= 0)
    verify(texts.indexOf("Prepare…") >= 0, "Prepare rows stay in Health")
    verify(texts.indexOf("Basic") < 0, "the level chooser left Health")
    mouseClick(findText("Open Style"))
    compare(shell.page, "style")
    verify(!shell.settingsOpen)
  }

  function findSidebar(item) {
    if (item.focusedIndex !== undefined && item.arrowNav !== undefined) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findSidebar(item.children[i])
      if (found) return found
    }
    return null
  }

  function ringOwner(bar) { return bar.ringKey() }

  function test_sidebar_click_selects_without_a_ring() {
    tc.dark = false
    setScene("home")
    var bar = findSidebar(shell)
    verify(bar, "sidebar found")
    mouseClick(findText("Dictionary"))
    compare(shell.page, "dictionary")
    compare(bar.focusedIndex(), 2, "the clicked row holds focus")
    compare(ringOwner(bar), "", "no ring after a click")
  }

  function test_sidebar_arrows_move_selection_and_ring() {
    tc.dark = false
    setScene("home")
    var bar = findSidebar(shell)
    mouseClick(findText("Stats"))
    compare(shell.page, "stats")
    keyClick(Qt.Key_Down)
    compare(shell.page, "dictionary")
    compare(ringOwner(bar), "dictionary")
    keyClick(Qt.Key_Down)
    compare(shell.page, "transforms")
    compare(ringOwner(bar), "transforms")
    keyClick(Qt.Key_Up)
    compare(shell.page, "dictionary")
    compare(ringOwner(bar), "dictionary")
  }

  function test_sidebar_steps_from_the_focused_row() {
    tc.dark = false
    setScene("home")
    var bar = findSidebar(shell)
    mouseClick(findText("Style"))
    // The page moves on from outside while focus stays on the Style row: the next arrow steps from the focused row.
    shell.navigate("home")
    compare(ringOwner(bar), "", "an outside page change drops the ring")
    keyClick(Qt.Key_Up)
    compare(shell.page, "transforms")
    compare(ringOwner(bar), "transforms")
  }
}
