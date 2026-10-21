import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "design"
import "transform"
import "transform/TransformModel.js" as Model

// Transform Selection: a floating card over the app that owns the selection. Service.qml loads this file once it exists.
//
// Opening: `control.py transform-open` (bound to a key) captures the selection and writes the reply to
// $XDG_RUNTIME_DIR/mouthtype/panel-transform.json. This window polls that file and shows the card for a fresh reply.
// Capturing happens in the key's own process, before any focus change, which is what keeps the text and the window
// together.
//
// Focus: the layer surface asks for keyboard focus on demand only, so it does not take focus when it appears; it gets
// it when the user clicks into the result box. Accept puts focus back on the captured window with
// `hyprctl dispatch focuswindow address:...` (control.py transform-focus) before it asks for the replacement.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string plugin: home + "/.config/omarchy/plugins/dstahl.mouthtype"
  readonly property string helper: plugin + "/control.py"
  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property string requestPath: runtime === "" ? "" : runtime + "/mouthtype/panel-transform.json"

  property var session: Model.empty()
  property real lastOpened: 0
  readonly property bool showing: session.phase !== "closed"

  function log(text) { console.log("mouthtype transform: " + text) }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function parse(raw) {
    try {
      var value = JSON.parse(String(raw || ""))
      return value && typeof value === "object" ? value : ({ error: "Transform Selection is unavailable." })
    } catch (e) { return ({ error: "Transform Selection is unavailable." }) }
  }

  // Run a process, or stop the one running and run this after it exits.
  function launch(proc, command) {
    proc.queued = command
    if (proc.running) { proc.signal(15); return }
    proc.queued = null
    proc.command = command
    proc.running = true
  }

  function consume(raw) {
    var request = parse(raw)
    var opened = Number(request.opened_at || 0)
    if (!(opened > lastOpened)) return
    lastOpened = opened
    // A file left over from an earlier session must not pop the card up when the shell restarts.
    if (Date.now() / 1000 - opened > 30) return
    openWith(request)
  }

  function openWith(request) {
    if (runProc.running) runProc.signal(15)
    panelWindow.screen = focusedScreen()
    session = Model.fromCapture(request)
    if (session.phase === "starting") launch(statusProc, [helper, "transform-status"])
  }

  function start(kind) {
    if (Model.isBusy(session) || session.id === "") return
    session = Model.runStarted(session, kind)
    launch(runProc, [helper, "transform-run", session.id, kind])
  }

  function runAction(command, handler) {
    if (actionProc.running) return false
    actionProc.handler = handler
    actionProc.command = command
    actionProc.running = true
    return true
  }

  function close() {
    if (session.phase === "accepting") return
    var id = session.id
    if (runProc.running) runProc.signal(15)
    session = Model.empty()
    if (id !== "" && !cancelProc.running) {
      cancelProc.command = [helper, "transform-cancel", id]
      cancelProc.running = true
    }
  }

  function editedFor(text) {
    return text !== session.serverResult ? [String(text).replace(/\u0000/g, "")] : []
  }

  function accept() {
    var text = card.resultText
    if (!Model.canAccept(session, text) || actionProc.running) return
    var id = session.id
    var command = [helper, "transform-accept", id].concat(editedFor(text))
    var address = session.app && session.app.address ? String(session.app.address) : ""
    session = Model.accepting(session)
    var finish = function(reply) { if (session.id === id) session = Model.absorbAccept(session, reply) }
    // Focus goes back first. If it can't, accept still runs and refuses cleanly when the window isn't the captured one.
    if (address !== "") runAction([helper, "transform-focus", address], function() { runAction(command, finish) })
    else runAction(command, finish)
  }

  function copy(which) {
    var text = card.resultText
    if (actionProc.running) return
    var id = session.id
    var command = [helper, "transform-copy", id, which]
    if (which === "result") {
      if (!Model.canCopy(session, text)) return
      command = command.concat(editedFor(text))
    }
    runAction(command, function(reply) { if (session.id === id) session = Model.absorbCopy(session, reply) })
  }

  Timer {
    interval: 400
    running: root.requestPath !== ""
    repeat: true
    onTriggered: requestFile.reload()
  }
  FileView {
    id: requestFile
    path: root.requestPath
    printErrors: false
    onLoaded: root.consume(text())
  }

  Process {
    id: statusProc
    property var queued: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (statusProc.queued !== null || root.session.phase !== "starting") return
        root.session = Model.withStatus(root.session, root.parse(text))
        root.start("clean-up")
      }
    }
    onExited: if (queued !== null) { command = queued; queued = null; running = true }
  }

  Process {
    id: runProc
    property var queued: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = root.parse(text)
        if (runProc.queued !== null || root.session.phase !== "running") return
        if (reply.id !== undefined && reply.id !== root.session.id) return
        root.session = Model.absorbRun(root.session, reply)
      }
    }
    onExited: if (queued !== null) { command = queued; queued = null; running = true }
  }

  Process {
    id: actionProc
    property var handler: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var done = actionProc.handler
        actionProc.handler = null
        if (done) done(root.parse(text))
      }
    }
  }

  Process { id: cancelProc }

  PanelWindow {
    id: panelWindow
    visible: root.showing && screen !== null
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "mouthtype-transform"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    TransformPanel {
      id: card
      focus: true
      session: root.session
      onChosen: function(kind) { root.start(kind) }
      onRetryRequested: root.start(root.session.kind)
      onCopyResultRequested: root.copy("result")
      onCopyOriginalRequested: root.copy("original")
      onAcceptRequested: root.accept()
      onCancelRequested: root.close()
    }
  }

  Component.onCompleted: log("loaded")
}
