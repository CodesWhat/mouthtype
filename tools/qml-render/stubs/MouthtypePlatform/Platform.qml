pragma Singleton
import QtQuick
import RenderHarness

// Replays RenderRegistry.replies for AppState, keyed by argv[1] like the Quickshell Process stub. A command with no reply
// completes with empty output, so the state stays as the case set it. Files never change and nothing is watched.
QtObject {
  id: root

  readonly property bool isLayerShell: true
  readonly property var focusedScreen: null

  function env(name) { return name === "HOME" ? RenderRegistry.home : "" }

  function run(argv, onDone) {
    var key = argv && argv.length > 1 ? String(argv[1]) : ""
    var reply = RenderRegistry.replies[key]
    var out = reply === undefined ? "" : (typeof reply === "string" ? reply : JSON.stringify(reply))
    runner.createObject(root, { out: out, done: onDone }).start()
  }

  function watch(path, onChange) { return { destroy: function() {} } }
  function readFile(path) { return "" }
  function openUrl(url) {}

  property Component runner: Component {
    Timer {
      property string out: ""
      property var done: null
      interval: 0
      onTriggered: { if (done) done(out, 0); destroy() }
    }
  }
}
