import QtQuick
import "../plugin" as Plugin

// The classic capsule after a take, showing a settled message with a detail line.
Item {
  id: scene
  width: 420
  height: 120
  property int settleMs: 500
  property var targets: [{ name: "", surface: "pill-window" }]

  Plugin.Service { id: service }

  function setup() {
    service.showMessageFor({ headline: "Couldn't transcribe", detail: "Audio saved for retry", isError: true }, 120)
  }
}
