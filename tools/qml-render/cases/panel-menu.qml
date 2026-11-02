import QtQuick
import RenderHarness
import "../plugin" as Plugin

// The bar menu on its main page with a running service, a few takes and a transcribe-file capability.
Item {
  id: scene
  width: 420
  height: 1100
  property int settleMs: 300
  property var targets: [{ name: "popup", surface: "panel-popup" }, { name: "bar", surface: "bar-button" }]

  Plugin.Panel { id: panel; opened: true }

  function setup() {
    RenderRegistry.replies = { state: {
      running: true, state: "idle", has_transcript: true, words_today: 142,
      recent: [{ id: "a", preview: "Remind me to send the invoice on Friday" }, { id: "b", preview: "The quick brown fox" }],
      saved: [], sounds: true, autostart: true,
      config: { delivery_mode: "paste", cleanup: "fast" },
      capabilities: { file_transcription: true },
      pill: { enabled: true, skin: "classic", size: 1 },
      history: { takes: 24, maximum: 200 }
    } }
    panel.refresh()
  }
}
