pragma Singleton
import QtQuick

// Scripted stand-in for the host platform, used by qmltestrunner where no Quickshell or Qt host exists. Same API as
// platform/quickshell/MouthtypePlatform/Platform.qml. Tests set `envValues`, `files` and `replies`, then read `calls`.
//
// `replies` maps argv.join(" ") to { out: "stdout", code: 0 }. An argv with no reply completes with ("", 127).
// Completion is asynchronous (one event-loop turn), like the real hosts.
QtObject {
  id: root

  property var envValues: ({})
  property var files: ({})
  property var replies: ({})
  property var calls: []
  property var urls: []
  property var focusedScreen: null
  property bool isLayerShell: false

  property var watchers: []

  function reset() {
    envValues = ({})
    files = ({})
    replies = ({})
    calls = []
    urls = []
    watchers = []
    isLayerShell = false
  }

  function env(name) {
    var value = envValues[name]
    return value === undefined ? "" : String(value)
  }

  function run(argv, onDone) {
    var key = argv.join(" ")
    calls = calls.concat([argv.slice()])
    var reply = replies[key] || { out: "", code: 127 }
    var entry = runner.createObject(root, { out: String(reply.out || ""), code: reply.code === undefined ? 0 : reply.code, done: onDone })
    entry.start()
  }

  function watch(path, onChange) {
    var handle = { path: path, notify: onChange, active: true, destroy: function() { this.active = false } }
    watchers = watchers.concat([handle])
    var initial = files[path]
    if (initial !== undefined) fire(handle, String(initial))
    return handle
  }

  function readFile(path) {
    var value = files[path]
    return value === undefined ? "" : String(value)
  }

  function openUrl(url) {
    urls = urls.concat([String(url)])
  }

  // Test hook: change a watched file as the host would.
  function writeFile(path, text) {
    var next = {}
    for (var key in files) next[key] = files[key]
    next[path] = text
    files = next
    for (var i = 0; i < watchers.length; i++) if (watchers[i].path === path && watchers[i].active) fire(watchers[i], String(text))
  }

  function fire(handle, text) {
    firer.createObject(root, { handle: handle, text: text }).start()
  }

  property Component runner: Component {
    Timer {
      property string out: ""
      property int code: 0
      property var done: null
      interval: 0
      repeat: false
      function start() { running = true }
      onTriggered: { if (done) done(out, code); destroy() }
    }
  }

  property Component firer: Component {
    Timer {
      property var handle: null
      property string text: ""
      interval: 0
      repeat: false
      function start() { running = true }
      onTriggered: { if (handle && handle.active && handle.notify) handle.notify(text); destroy() }
    }
  }
}
