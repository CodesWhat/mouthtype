import QtQuick
import RenderHarness
import "../plugin" as Plugin

// The Settings sheet on its Health tab (openPage("cleanup") lands there), one cleanup model prepared and one not.
Item {
  id: scene
  width: 420
  height: 600
  property int settleMs: 300
  property var targets: [{ name: "popup", surface: "panel-popup" }]

  Plugin.Panel { id: panel; opened: true }

  function setup() {
    RenderRegistry.replies = { state: {
      running: true, state: "idle", config: { cleanup: "basic" },
      cleanup: { models: { fast: "prepared", thorough: "absent" }, setup: null, service: null }
    } }
    panel.refresh()
    panel.openPage("cleanup")
  }
}
