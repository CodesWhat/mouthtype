pragma Singleton
import QtQuick

// Shared state between the test wrapper and the stubs. The wrapper sets host, home, dark and replies; stubs
// register the surfaces a case can capture by name.
QtObject {
  property Item host: null
  property string home: "/tmp/mouthtype-render-home"
  property bool dark: false
  readonly property color backdrop: dark ? "#1E1E20" : "#EDEDEF"
  // Canned stdout for Process stubs, keyed by the first argument after the executable, e.g. { state: {...} }.
  property var replies: ({})
  property var surfaces: ({})

  function register(name, item) {
    var next = {}
    for (var key in surfaces) next[key] = surfaces[key]
    next[name] = item
    surfaces = next
  }
}
