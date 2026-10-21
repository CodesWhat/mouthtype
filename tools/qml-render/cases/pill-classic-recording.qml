import QtQuick
import "../plugin" as Plugin

// The classic capsule while recording, fed one state event the way the watcher feeds it.
Item {
  id: scene
  width: 420
  height: 120
  property int settleMs: 500
  property var targets: [{ name: "", surface: "pill-window" }]

  Plugin.Service { id: service }

  function setup() {
    service.handle(JSON.stringify({ event: "state", state: "recording", level: -18, elapsed: 4.2 }))
  }
}
