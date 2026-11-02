import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "design"

// The bar widget and panel host. AppState owns the state and the control.py processes; this file owns the bar button, the
// IPC handler and the panel. MouthtypeShell draws the window (sidebar, pages, Settings modal) and the files in pages/ draw
// each page. Pages receive the AppState as `host`.
Panel {
  id: root
  moduleName: "dstahl.mouthtype"
  ipcTarget: "dstahl.mouthtype"
  manageIpc: false

  readonly property string helper: Quickshell.env("HOME") + "/.config/omarchy/plugins/dstahl.mouthtype/control.py"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // All state and the control.py processes live in AppState; this file is the Omarchy bar glue around it.
  AppState {
    id: app
    helper: root.helper
    opened: root.opened
    shell: shellView
    fallbackFont: Style.font.family
    onOpenRequested: root.open()
    onCloseRequested: root.close()
  }

  function refresh() { app.refresh() }
  function openPage(name) { app.openPage(name) }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function openPage(name: string): void { root.openPage(name); if (!root.opened) root.open() }
    function startCapture(): void { if (!root.opened) root.open(); shellView.beginCapture() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: Style.bar.iconSlot
    tooltipText: "Mouthtype · " + (app.serviceRunning ? app.sessionState : "off")
    active: app.sessionState === "recording"
    Image {
      id: statusGlyph
      anchors.centerIn: parent
      width: Style.space(16)
      height: Style.space(15)
      source: Qt.resolvedUrl("assets/glyph-" + app.glyphState + "@2x.png")
      sourceSize.width: 32
      sourceSize.height: 30
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }
    MultiEffect {
      anchors.fill: statusGlyph
      source: statusGlyph
      colorization: 1.0
      colorizationColor: app.sessionState === "recording"
        ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    }
    onPressed: function(code) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    padding: 0
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(900))
    contentHeight: panel.fittedContentHeight(Style.space(620), Style.space(620))

    Rectangle {
      anchors.fill: parent
      radius: Style.space(9)
      color: Theme.bg
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: shellView.editing
      onCloseRequested: { if (!shellView.dismissLayer()) root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      MouthtypeShell {
        id: shellView
        anchors.fill: parent
        host: app
        onPageRequested: function(command, args) { app.pageRequest(command, args) }
      }
    }
  }
}
