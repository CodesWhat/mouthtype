pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Host services for the shared QML, Quickshell/Omarchy implementation. The Qt host ships a second module with the same URI and
// API (tools/linux-qt), and design/render/fake has the scripted one used by tests. Keep the three in step; test_platform.py
// checks the names.
//
//   env(name)            -> string, "" when unset
//   run(argv, onDone)    -> runs argv, calls onDone(stdoutText, exitCode) once; exitCode is -1 when it could not start
//   watch(path, onChange)-> handle (destroy() to stop); onChange(text) fires on load and on every change of the file
//   readFile(path)       -> string, "" when missing
//   focusedScreen        -> the screen holding focus (Hyprland's focused output), first screen otherwise
//   isLayerShell         -> true when the host can draw layer-shell surfaces
//   openUrl(url)
Singleton {
  id: root

  readonly property bool isLayerShell: true

  // Matched by name as the bar does; the first screen otherwise.
  readonly property var focusedScreen: {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function env(name) {
    return String(Quickshell.env(name) || "")
  }

  function run(argv, onDone) {
    procComponent.createObject(root, { command: argv, done: onDone })
  }

  function watch(path, onChange) {
    return watchComponent.createObject(root, { path: path, notify: onChange })
  }

  function readFile(path) {
    var reader = readComponent.createObject(root, { path: path })
    var text = ""
    try { text = String(reader.text() || "") } catch (e) { text = "" }
    reader.destroy()
    return text
  }

  function openUrl(url) {
    Quickshell.execDetached(["xdg-open", String(url)])
  }

  Component {
    id: procComponent
    Process {
      id: proc
      property var done: null
      property string output: ""
      property int code: -1
      property bool gotOutput: false
      property bool gotExit: false
      running: true

      function finish() {
        if (!gotOutput || !gotExit) return
        var callback = done
        done = null
        if (callback) callback(output, code)
        proc.destroy()
      }

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { proc.output = String(text || ""); proc.gotOutput = true; proc.finish() }
      }
      onExited: function(exitCode) { proc.code = exitCode; proc.gotExit = true; proc.finish() }
    }
  }

  Component {
    id: watchComponent
    FileView {
      property var notify: null
      watchChanges: true
      printErrors: false
      onFileChanged: reload()
      onLoaded: if (notify) notify(String(text() || ""))
    }
  }

  Component {
    id: readComponent
    FileView {
      blockLoading: true
      printErrors: false
    }
  }
}
