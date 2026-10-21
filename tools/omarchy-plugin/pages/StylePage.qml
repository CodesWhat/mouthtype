import QtQuick
import "../design"
import "style"
import "style/StyleLogic.js" as Logic

// Style: a tone for each kind of writing, the apps that count as each kind, and how much cleanup runs. Five tabs: Personal
// messages, Work messages, Email, Other and Cleanup. Page contract: see MouthtypeShell.qml.
//
// Every number and sample on the page comes from `style-state` (control_style.py). An edit verb replies with the same shape
// so the newest reply of any style verb is the current state and the page does not re-read after an
// edit. The global cleanup level is state.config.cleanup, set through set-config as Settings, Health used to do.
Item {
  id: root

  property var backend: ({})
  property bool active: false
  signal request(string command, var args)

  // "personal", "work", "email", "other" or "cleanup".
  property string tab: "personal"
  property var styles: null
  property string editError: ""
  property var seen: ({})

  readonly property var watched: ["style-state", "style-set-default-tone", "style-set-tone", "style-set-cleanup", "style-add-app",
    "style-remove-app", "style-rule", "set-config", "cleanup-setup"]
  readonly property var tabIds: ["personal", "work", "email", "other", "cleanup"]
  readonly property var contexts: styles ? styles.contexts : []
  readonly property var tones: styles ? styles.tones : []
  readonly property var appState: backend && backend.state ? backend.state : ({})
  readonly property var config: appState.config ? appState.config : ({})
  readonly property string globalLevel: config.cleanup === "basic" || config.cleanup === "fast" || config.cleanup === "thorough" ? config.cleanup : "off"
  readonly property var cleanupInfo: appState.cleanup ? appState.cleanup : ({ models: {}, setup: null, service: null })
  readonly property var current: contextById(tab)

  implicitHeight: column.implicitHeight

  function contextById(id) {
    for (var i = 0; i < contexts.length; i++) if (contexts[i].id === id) return contexts[i]
    return null
  }

  function titles() {
    var out = []
    for (var i = 0; i < tabIds.length - 1; i++) {
      var context = contextById(tabIds[i])
      out.push(context ? context.title : tabIds[i])
    }
    out.push("Cleanup")
    return out
  }

  function refresh() { request("style-state", []) }

  // Send a list of [verb, args] control.py requests in order.
  function send(requests) {
    editError = ""
    for (var i = 0; i < requests.length; i++) request(requests[i][0], requests[i][1])
  }

  // Take in whatever style replies arrived since the last look. A reply with `contexts` is a full state; one with `error`
  // leaves the state alone and shows its message. set-config and cleanup-setup are watched only for their errors.
  function absorb() {
    var results = backend && backend.results ? backend.results : ({})
    var next = {}
    for (var key in seen) next[key] = seen[key]
    for (var i = 0; i < watched.length; i++) {
      var verb = watched[i]
      var reply = results[verb]
      if (reply === undefined || reply === null || reply === seen[verb]) continue
      next[verb] = reply
      if (reply.error) { editError = String(reply.error); continue }
      editError = ""
      if (reply.contexts !== undefined) styles = reply
    }
    seen = next
  }

  onBackendChanged: absorb()
  onActiveChanged: if (active) refresh()
  Component.onCompleted: { absorb(); startup.start() }

  // The shell wires `request` and `active` after the page is created, so the first read waits a beat.
  Timer {
    id: startup
    interval: 80
    onTriggered: if (root.active && root.styles === null) root.refresh()
  }

  Column {
    id: column
    width: parent.width
    spacing: 18

    DesignPageHeader {
      width: parent.width
      title: "Style"
      summary: "A tone for each kind of writing, and the apps that count as each kind."
    }

    DesignCard {
      width: parent.width
      visible: root.editError !== ""
      DesignRow {
        title: root.editError
        Icon { name: "warning"; size: 24; color: Theme.danger }
      }
    }

    DesignCard {
      width: parent.width
      visible: root.styles === null
      DesignRow {
        title: root.editError !== "" ? "Style could not be read" : "Reading your Style settings…"
        detail: root.editError !== "" ? "The rest of the panel still works." : ""
      }
    }

    Column {
      width: parent.width
      spacing: 18
      visible: root.styles !== null

      StyleTabs {
        id: tabs
        width: parent.width
        titles: root.titles()
        currentIndex: Math.max(0, root.tabIds.indexOf(root.tab))
        onActivated: function(index) { root.tab = root.tabIds[index] }
      }

      ContextTab {
        id: contextTab
        visible: root.tab !== "cleanup" && root.current !== null
        width: parent.width
        context: root.current ? root.current : ({})
        tones: root.tones
        rules: root.styles ? root.styles.rules : []
        ownRules: root.styles ? Logic.ownRules(root.styles) : []
        globalLevel: root.globalLevel
        onEdit: function(requests) { root.send(requests) }
      }

      CleanupTab {
        id: cleanupTab
        visible: root.tab === "cleanup"
        width: parent.width
        contexts: root.contexts
        overrides: root.styles ? root.styles.cleanup_overrides : []
        rules: root.styles ? root.styles.rules : []
        level: root.globalLevel
        models: root.cleanupInfo.models ? root.cleanupInfo.models : ({})
        service: root.cleanupInfo.service ? root.cleanupInfo.service : null
        setup: root.cleanupInfo.setup ? root.cleanupInfo.setup : null
        onChooseLevel: function(level) { root.send([["set-config", ["cleanup", level]]]) }
        onPrepare: function(level) { root.send([["cleanup-setup", [level]]]) }
        onOpenContext: function(id) { root.tab = id }
      }
    }
  }
}
