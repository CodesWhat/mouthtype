pragma Singleton
import QtQuick

// Host services for the shared QML, Qt (PySide6) implementation. The Quickshell host ships a second module with the same URI
// and API (tools/omarchy-plugin/platform/quickshell), and design/render/fake has the scripted one used by tests. Keep the
// three in step; test_platform.py checks the names. The work happens in the `PlatformBackend` context property that
// mouthtype_desktop.py sets (QProcess, QFileSystemWatcher); this file is the QML face of it.
//
//   env(name)            -> string, "" when unset
//   run(argv, onDone)    -> runs argv, calls onDone(stdoutText, exitCode) once; exitCode is -1 when it could not start
//   watch(path, onChange)-> handle (destroy() to stop); onChange(text) fires on load and on every change of the file
//   readFile(path)       -> string, "" when missing
//   focusedScreen        -> the first screen (Wayland clients cannot ask which output has focus)
//   isLayerShell         -> true when the host can draw layer-shell surfaces (the KDE pill, Q6)
//   openUrl(url)
QtObject {
  id: root

  readonly property bool isLayerShell: PlatformBackend.layerShell
  readonly property var focusedScreen: Qt.application.screens.length ? Qt.application.screens[0] : null

  property int nextId: 1
  property var pending: ({})
  property var watchers: ({})

  function env(name) {
    return String(PlatformBackend.env(String(name)) || "")
  }

  function run(argv, onDone) {
    var id = nextId++
    pending[id] = onDone
    PlatformBackend.run(id, argv.map(String))
  }

  function watch(path, onChange) {
    var handle = { path: String(path), notify: onChange, active: true, destroy: function() { this.active = false; PlatformBackend.unwatch(this.path) } }
    watchers[handle.path] = handle
    PlatformBackend.watch(handle.path)
    return handle
  }

  function readFile(path) {
    return String(PlatformBackend.readFile(String(path)) || "")
  }

  function openUrl(url) {
    PlatformBackend.openUrl(String(url))
  }

  property Connections backend: Connections {
    target: PlatformBackend
    function onFinished(id, out, code) {
      var callback = root.pending[id]
      delete root.pending[id]
      if (callback) callback(String(out), code)
    }
    function onChanged(path, text) {
      var handle = root.watchers[path]
      if (handle && handle.active && handle.notify) handle.notify(String(text))
    }
  }
}
