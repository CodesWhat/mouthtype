import QtQuick
import RenderHarness

// Inert unless RenderRegistry.replies has an entry for command[1]; then it replays that JSON as stdout once.
QtObject {
  id: root
  property var command: []
  property bool running: false
  property QtObject stdout: null
  signal exited()

  onRunningChanged: if (running) replay.restart()

  readonly property Timer replayTimer: Timer {
    id: replay
    interval: 0
    onTriggered: {
      var key = root.command && root.command.length > 1 ? String(root.command[1]) : ""
      var reply = RenderRegistry.replies[key]
      if (reply !== undefined && root.stdout) {
        root.stdout.text = typeof reply === "string" ? reply : JSON.stringify(reply)
        root.stdout.streamFinished()
      }
      root.running = false
      root.exited()
    }
  }
}
