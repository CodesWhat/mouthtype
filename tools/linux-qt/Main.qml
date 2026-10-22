import QtQuick
import QtQuick.Window
import MouthtypePlatform
import "../omarchy-plugin"
import "../omarchy-plugin/design"

// The GNOME and KDE settings window: the shared AppState and MouthtypeShell in a plain top-level window. The Python host
// (mouthtype_desktop.py) sets the context properties `Host` (helper, startPage, dark, screenshotPath), `PlatformBackend` and `Tray`.
Window {
  id: win

  width: 960
  height: 680
  minimumWidth: 640
  minimumHeight: 460
  title: "Mouthtype"
  color: Theme.bg
  visible: false

  Binding { target: Theme; property: "forceDark"; value: Host.dark }

  AppState {
    id: app
    helper: Host.helper
    opened: win.visible
    shell: shellView
    fallbackFont: Qt.application.font.family
    onOpenRequested: { win.visible = true; win.raise(); win.requestActivate() }
    onCloseRequested: win.visible = false
  }

  Binding { target: app; property: "trayAvailable"; value: Tray.available }
  Connections {
    target: app
    function onGlyphStateChanged() { Tray.setGlyph(app.glyphState) }
  }
  Connections {
    target: Tray
    function onActionRequested(action) {
      if (action === "toggle") app.run(["toggle"])
      else if (action === "open") { app.openPage("home"); app.open() }
      else if (action === "settings") { app.openPage("general"); app.open() }
    }
  }

  // The KDE pill. PillWindow.qml imports org.kde.layershell, so it is only loaded where the host found that module.
  Loader {
    id: pillLoader
    active: Platform.isLayerShell
    source: "PillWindow.qml"
    onLoaded: item.app = app
    onStatusChanged: if (status === Loader.Error) Host.failed("the pill could not load (is qml6-module-org-kde-layershell installed?)")
  }

  MouthtypeShell {
    id: shellView
    anchors.fill: parent
    host: app
    focus: true
    onPageRequested: function(command, args) { app.pageRequest(command, args) }
    Keys.onEscapePressed: { if (!shellView.dismissLayer()) win.visible = false }
  }

  Connections {
    target: Host
    function onPageRequested(name) { app.openPage(name); app.open() }
  }

  // Launch, then report back once the first state reply and the requested page have been drawn (selftest and screenshots).
  property bool stateSeen: false
  Connections {
    target: app
    function onServiceRunningChanged() { win.stateSeen = true }
    function onLastStateChanged() { win.stateSeen = true }
  }
  Timer {
    id: settle
    interval: Host.settleMs
    running: win.stateSeen
    onTriggered: {
      if (Host.pillScreenshotPath !== "") return
      if (Host.screenshotPath === "") { Host.loaded(); return }
      shellView.grabToImage(function(result) {
        if (result && result.saveToFile(Host.screenshotPath)) Host.loaded()
        else Host.failed("could not save " + Host.screenshotPath)
      })
    }
  }
  Timer { interval: 8000; running: Host.watchdog; onTriggered: Host.failed("timed out waiting for the first state reply") }

  Component.onCompleted: {
    Tray.setGlyph(app.glyphState)
    app.refresh()
    app.openPage(Host.startPage)
    if (!Host.background) app.open()
  }
}
