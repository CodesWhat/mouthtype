import QtQuick
import RenderHarness
import "../plugin" as Plugin

// The menu while recording: Stop and Cancel replace Start, and the bar glyph turns urgent.
Item {
  id: scene
  width: 420
  height: 800
  property int settleMs: 300
  property var targets: [{ name: "popup", surface: "panel-popup" }, { name: "bar", surface: "bar-button" }]

  Plugin.Panel { id: panel; opened: true }

  function setup() {
    RenderRegistry.replies = { state: { running: true, state: "recording", has_transcript: false, config: { delivery_mode: "recover" } } }
    panel.refresh()
  }
}
