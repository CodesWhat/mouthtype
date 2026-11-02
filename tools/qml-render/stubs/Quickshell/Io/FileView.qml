import QtQuick

// Reads local files through XMLHttpRequest (the runner sets QML_XHR_ALLOW_FILE_READ=1). Never watches.
QtObject {
  id: root
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: true
  property string content: ""
  signal loaded()
  signal loadFailed(var error)
  signal fileChanged()

  function text() { return content }
  function reload() { load() }

  function load() {
    if (path === "") return
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (request.responseText !== "") {
        root.content = request.responseText
        root.loaded()
      } else {
        root.loadFailed(request.status)
      }
    }
    request.open("GET", "file://" + path)
    request.send()
  }

  onPathChanged: load()
  Component.onCompleted: load()
}
