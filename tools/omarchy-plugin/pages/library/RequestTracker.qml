import QtQuick
import "LibraryModel.js" as Model

// Turns the shell's request/backend contract into send and finished. A page calls send(verb, args) for one request at a time;
// when backend.results[verb] holds a reply newer than the one read at send time and the shell is not busy, `finished` fires with
// it. A request that ends with no new reply and a shell error finishes with { error }.
QtObject {
  id: root

  property var backend: ({})
  property string pending: ""
  property var before: null
  property bool seenBusy: false
  readonly property bool waiting: pending !== ""
  // The page connects this to its own `request` signal.
  signal dispatch(string command, var args)
  signal finished(string command, var reply)

  function send(command, args) {
    if (pending !== "") return false
    var results = backend && backend.results ? backend.results : ({})
    before = results[command]
    seenBusy = false
    pending = command
    dispatch(command, args || [])
    return true
  }

  function check() {
    if (pending === "" || !backend) return
    if (backend.busy === true) { seenBusy = true; return }
    var results = backend.results ? backend.results : ({})
    var reply = results[pending]
    var done = pending
    if (Model.isFresh(reply, before)) {
      pending = ""
      finished(done, reply)
    } else if (seenBusy && backend.error) {
      pending = ""
      finished(done, { error: String(backend.error) })
    }
  }

  onBackendChanged: check()
}
