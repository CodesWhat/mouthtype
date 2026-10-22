import QtQuick
import QtQuick.Window
import MouthtypePlatform
import "../omarchy-plugin"
import "../omarchy-plugin/design"

// The GNOME and KDE settings window: the shared AppState and MouthtypeShell in a plain top-level window. The Python host
// (mouthtype_desktop.py) sets the context properties `Host` (helper, startPage, dark, screenshotPath) and `PlatformBackend`.
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
      if (Host.screenshotPath === "") { Host.loaded(); return }
      shellView.grabToImage(function(result) {
        if (result && result.saveToFile(Host.screenshotPath)) Host.loaded()
        else Host.failed("could not save " + Host.screenshotPath)
      })
    }
  }
  Timer { interval: 8000; running: Host.watchdog; onTriggered: Host.failed("timed out waiting for the first state reply") }

  Component.onCompleted: {
    app.refresh()
    app.openPage(Host.startPage)
    app.open()
  }
}
