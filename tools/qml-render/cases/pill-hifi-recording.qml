import QtQuick
import "../plugin" as Plugin

// The Hi-Fi skin at 2x while recording. Prefs are set after the stub FileView has finished failing to find them.
Item {
  id: scene
  width: 420
  height: 120
  property int settleMs: 600
  property var targets: [{ name: "", surface: "pill-window" }]

  Plugin.Service { id: service }

  function setup() {
    service.prefs = { pill: { enabled: true, skin: "hifi", size: 2 } }
    service.handle(JSON.stringify({ event: "state", state: "recording", level: -24, elapsed: 1.0 }))
  }
}
