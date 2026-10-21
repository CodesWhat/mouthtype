import QtQuick
import "LibraryModel.js" as Model

// Turns the shell's request/backend contract into send and finished. A page calls send(verb, args) for one request at a time.
// The shell has no request ids, so completion is the falling edge of backend.busy: when it drops after our request started,
// `finished` fires with backend.results[verb] if that is a reply newer than the one read at send time, and otherwise with
// { error } (the shell's error text, or a plain "did not answer" for a missing or null reply). A request that was queued behind
// another one skips that one's falling edge first.
QtObject {
  id: root

  property var backend: ({})
  property string pending: ""
  property var before: null
  property bool sawBusy: false
  property int skip: 0
  readonly property bool waiting: pending !== ""
  // The page connects this to its own `request` signal.
  signal dispatch(string command, var args)
  signal finished(string command, var reply)

  function send(command, args) {
    if (pending !== "") return false
    var results = backend && backend.results ? backend.results : ({})
    before = results[command]
    skip = backend && backend.busy === true ? 1 : 0
    sawBusy = skip > 0
    pending = command
    dispatch(command, args || [])
    return true
  }

  function check() {
    if (pending === "" || !backend) return
    if (backend.busy === true) { sawBusy = true; return }
    if (!sawBusy) return
    sawBusy = false
    if (skip > 0) { skip--; return }
    var results = backend.results ? backend.results : ({})
    var reply = results[pending]
    var done = pending
    pending = ""
    var outcome = Model.isFresh(reply, before) ? reply : { error: String(backend.error || "Mouthtype did not answer") }
    // Deferred: a handler that sends the next request changes busy, and doing that while the backend binding is still
    // being evaluated makes the shell see a stale value.
    Qt.callLater(function() { finished(done, outcome) })
  }

  onBackendChanged: check()
}
