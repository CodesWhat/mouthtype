import QtQuick
import QtTest
import ".."
import "../design"

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
      case "stats": shell.navigate("stats"); break
      case "dictionary": shell.navigate("dictionary"); break
      case "transforms": shell.navigate("transforms"); break
      case "style": shell.navigate("style"); break
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

  property var saved: ({})
  readonly property var scenes: ["home", "home-empty", "stats", "dictionary", "transforms", "style", "appearance", "appearance-hifi",
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
  }

  function test_nav_pages() {
    tc.dark = false
    setScene("home")
    compare(shell.page, "home")
    shell.navigate("dictionary")
    compare(shell.page, "dictionary")
    tryVerify(function() { return pageTitle() === "Dictionary" }, 2000)
    shell.navigate("stats")
    tryVerify(function() { return pageTitle() === "Stats" }, 2000)
    shell.navigate("transforms")
    tryVerify(function() { return pageTitle() === "Transforms" }, 2000)
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
    tryVerify(function() { return pageTitle() === "Dictionary" }, 2000)
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
}
