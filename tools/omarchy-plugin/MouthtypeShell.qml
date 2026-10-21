import QtQuick
import "design"

// The panel's window: sidebar on the left, one page on the right, the Settings modal and the shortcut recorder on top.
// It imports no Quickshell types, so the render harness loads it with a fixture `host`.
//
// PAGE CONTRACT (the slices that build Stats, Dictionary, Transforms and Style rely on this):
//   File:       pages/StatsPage.qml, pages/DictionaryPage.qml, pages/TransformsPage.qml, pages/StylePage.qml.
//   Root:       an Item with an implicitHeight. The shell gives it the content width and scrolls it.
//   Properties: `property var backend` (set by the shell, see below) and `property bool active` (true while it is the shown page).
//   Signal:     `signal request(string command, var args)`. command is a control.py verb, args a list of strings. The shell runs
//               `control.py <command> <args...>`, parses its JSON stdout, and publishes it as backend.results[command].
//   backend:    { state, results, busy, error, dark }. `state` is the last `control.py state` JSON (config, versions, ...).
//               `results` maps a verb to its last parsed JSON reply. `busy` is true while a request is running. `error` is
//               the last request's message, "" when it succeeded. A new object is assigned on every change, so bindings update.
//   Verbs:      anything control.py accepts, built in or from a control_<name>.py module. Requests run one at a time, in order.
// Built-in pages (Home, Appearance, the settings tabs) take `property var host` instead and call host.run([...]).
Item {
  id: root

  property var host: null
  property string page: "home"
  property bool settingsOpen: false
  property string settingsTab: "general"
  property bool shortcutOpen: false
  property bool advancedOptions: false
  property var pageResults: ({})
  property bool pageBusy: false
  property string pageError: ""
  signal pageRequested(string command, var args)

  readonly property string navKey: page === "transcript" || page === "import" ? "home" : page
  readonly property bool editing: shortcut.editing || settings.editing || (pageLoader.item ? pageLoader.item.editing === true : false)
  readonly property var backend: ({
    state: host && host.lastState ? host.lastState : ({}),
    results: pageResults,
    busy: pageBusy,
    error: pageError,
    dark: Theme.dark
  })
  readonly property var pageFiles: ({
    home: "HomePage", transcript: "TranscriptPage", "import": "TranscribeFilePage",
    stats: "StatsPage", dictionary: "DictionaryPage", transforms: "TransformsPage",
    style: "StylePage", appearance: "AppearancePage"
  })

  implicitWidth: 900
  implicitHeight: 620

  // Old menu page names (IPC openPage, `page` in a control.py reply) land on the nearest place in the new layout.
  function navigate(name) {
    name = String(name || "home")
    var settingsTabs = { cleanup: "health", history: "health", about: "health", help: "health",
                         delivery: "general", recording: "general", linux: "linux", advanced: "advanced", settings: "general", general: "general", health: "health" }
    if (name === "shortcut") { settingsOpen = true; settingsTab = "general"; shortcutOpen = true; return }
    if (settingsTabs[name] !== undefined) {
      if (settingsTabs[name] === "advanced") advancedOptions = true
      settingsTab = settingsTabs[name]
      settingsOpen = true
      return
    }
    if (name === "menu") name = "home"
    if (name === "pill" || name === "fonts") name = "appearance"
    if (pageFiles[name] === undefined) name = "home"
    page = name
    settingsOpen = false
    shortcutOpen = false
  }

  function pageResult(command, result) {
    var next = {}
    for (var key in pageResults) next[key] = pageResults[key]
    next[command] = result
    pageResults = next
    pageError = result && result.error ? String(result.error) : ""
  }

  function pageFailed(message) { pageError = String(message || "") }

  // dismissLayer peels one layer: the recorder, then the settings modal. False means nothing was open and the panel should close.
  function dismissLayer() {
    if (shortcutOpen) { shortcutOpen = false; return true }
    if (settingsOpen) { settingsOpen = false; return true }
    return false
  }

  function beginCapture() {
    navigate("shortcut")
    shortcut.beginCapture()
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.bg
  }

  MouthtypeSidebar {
    id: sidebar
    width: 220
    height: parent.height
    current: root.navKey
    settingsOpen: root.settingsOpen
    onActivated: function(key) { root.navigate(key) }
    onSettingsRequested: root.settingsOpen = true
  }

  Flickable {
    id: scroll
    x: sidebar.width
    width: parent.width - sidebar.width
    height: parent.height
    contentWidth: width
    contentHeight: pageLoader.height + 56 + (banner.visible ? banner.height + 16 : 0)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    onContentHeightChanged: returnToBounds()

    Loader {
      id: pageLoader
      x: 32
      y: 28
      width: scroll.width - 64
      height: item ? item.implicitHeight : fallback.height
      source: "pages/" + (root.pageFiles[root.page] || "HomePage") + ".qml"

      onLoaded: {
        if (item.host !== undefined) item.host = root.host
        if (item.request !== undefined) item.backend = Qt.binding(function() { return root.backend })
        if (item.active !== undefined) item.active = Qt.binding(function() { return !root.settingsOpen })
      }
    }

    Connections {
      target: pageLoader.item
      ignoreUnknownSignals: true
      function onRequest(command, args) { root.pageRequested(String(command), args || []) }
    }

    DesignCard {
      id: fallback
      visible: pageLoader.status === Loader.Error
      x: 32
      y: 28
      width: scroll.width - 64
      DesignRow {
        title: "This page is unavailable in this build"
        detail: "Its file is missing or failed to load. The rest of the panel still works."
        Icon { name: "warning"; size: 24; color: Theme.ink3 }
      }
    }
  }

  // Notices and errors from the last action, over the bottom of the page.
  DesignCard {
    id: banner
    visible: !!root.host && ((root.host.errorText || "") !== "" || (root.host.notice || "") !== "")
    x: sidebar.width + 32
    y: parent.height - height - 16
    width: parent.width - sidebar.width - 64
    DesignRow {
      title: root.host ? (root.host.errorText || root.host.notice || "") : ""
      Icon {
        visible: !!root.host && (root.host.errorText || "") !== ""
        name: "warning"
        size: 24
        color: Theme.danger
      }
    }
  }

  MouthtypeSettings {
    id: settings
    host: root.host
    open: root.settingsOpen
    tab: root.settingsTab
    advanced: root.advancedOptions
    onCloseRequested: root.settingsOpen = false
    onTabRequested: function(tab) { root.settingsTab = tab }
    onAdvancedToggled: function(on) {
      root.advancedOptions = on
      if (!on && root.settingsTab === "advanced") root.settingsTab = "general"
    }
  }

  MouthtypeShortcut {
    id: shortcut
    host: root.host
    open: root.shortcutOpen
    onCloseRequested: root.shortcutOpen = false
  }
}
