import QtQuick
import "../design"
import "../parts"

// Home: start and stop dictation, then recent takes newest first, grouped by day. Copy and Recover show on hover.
// Moved from the old menu's session rows, Recent Dictations list, Paste Last and Copy Last, with the same control.py verbs.
Column {
  id: root

  property var host: null
  property var backend: ({})
  property bool active: false
  signal request(string command, var args)
  // Unsaved Dictionary and Transforms sheets left behind by a quit, from control_library.py draft-list. A dismissed id stays
  // hidden until the next list reply, so a click answers at once.
  property var dismissed: []
  readonly property var drafts: draftRows(backend && backend.results ? backend.results["draft-list"] : null, dismissed)
  readonly property bool recording: !!host && host.sessionState === "recording"
  readonly property bool idle: !!host && (host.sessionState === "off" || host.sessionState === "idle")
  readonly property bool canDeliver: !!host && host.hasTranscript && (host.config.delivery_mode === "type" || host.config.delivery_mode === "paste")
  // The delivery choice, shown once while Mouthtype only saves takes. Choosing Paste changes the mode, which hides the card
  // by itself; "Just save them" sets welcomed so it stays hidden.
  readonly property bool showWelcome: !!host && host.config.delivery_mode === "recover" && !host.welcomed
  readonly property var groups: grouped(host ? host.recent : [], host ? host.saved : [])

  width: parent ? parent.width : 520
  spacing: 18

  function dayLabel(seconds) {
    var then = new Date(seconds * 1000)
    var today = new Date()
    var start = new Date(today.getFullYear(), today.getMonth(), today.getDate())
    var thenStart = new Date(then.getFullYear(), then.getMonth(), then.getDate())
    var days = Math.round((start.getTime() - thenStart.getTime()) / 86400000)
    if (days <= 0) return "Today"
    if (days === 1) return "Yesterday"
    return Qt.formatDate(then, "MMM d")
  }

  // Takes with a transcript and takes whose audio is saved without one, merged by time and split by day.
  function grouped(recent, saved) {
    var entries = []
    var i
    for (i = 0; i < (recent || []).length; i++) entries.push({ entry: recent[i], retry: false })
    for (i = 0; i < (saved || []).length; i++) entries.push({ entry: saved[i], retry: true })
    entries.sort(function(a, b) { return (b.entry.mtime || 0) - (a.entry.mtime || 0) })
    var result = []
    for (i = 0; i < entries.length; i++) {
      var label = dayLabel(entries[i].entry.mtime || 0)
      if (!result.length || result[result.length - 1].label !== label) result.push({ label: label, items: [] })
      result[result.length - 1].items.push(entries[i])
    }
    return result
  }

  function draftRows(reply, hidden) {
    var rows = reply && reply.drafts ? reply.drafts : []
    return rows.filter(function(d) { return hidden.indexOf(d.id) < 0 })
  }

  function draftTitle(d) {
    return d.kind === "phrase" ? "Unsaved transform \u201c" + (d.trigger || "") + "\u201d" : "Unsaved word \u201c" + (d.written || d.heardInput || "") + "\u201d"
  }

  function recoverDraft(d) {
    if (!host) return
    host.pendingDraft = d
    dismissed = dismissed.concat([d.id])
    host.openPage(d.kind === "phrase" ? "transforms" : "dictionary")
  }

  onActiveChanged: if (active) { dismissed = []; request("draft-list", []) }
  Component.onCompleted: if (active) request("draft-list", [])

  DesignPageHeader {
    width: parent.width
    title: "Your recent takes."
    summary: "Everything you dictated lately, newest first. Copy it or recover it."
  }

  DesignCard {
    visible: root.showWelcome
    width: parent.width
    DesignRow {
      title: "Where should your words go?"
      detail: "Linux can't tell password fields apart, so Mouthtype pastes wherever the cursor is."
      DesignSecondaryButton {
        text: "Just save them"
        onActivated: root.host.run(["set-plugin", "welcomed", "on"])
      }
      DesignPrimaryButton {
        text: "Paste where I'm typing (Recommended)"
        onActivated: root.host.run(["set-config", "delivery", "paste"])
      }
    }
    DesignRow {
      visible: !!root.host && root.host.shortcutMode !== "off"
      title: "Dictate from anywhere"
      detail: root.host && root.host.shortcutMode === "hold" ? "Hold this key, speak, then let go." : "Press this key, speak, then press it again."
      DesignKbd { text: root.host ? root.host.shortcutKeys : "" }
    }
  }

  Column {
    visible: root.drafts.length > 0
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Unsaved drafts" }
    DesignCard {
      width: parent.width
      Repeater {
        model: root.drafts
        delegate: HomeRow {
          required property var modelData
          title: root.draftTitle(modelData)
          detail: Qt.formatDateTime(new Date((modelData.saved || 0) * 1000), "MMM d, h:mm AP") + " · from when the sheet was closed unsaved"
          buttonText: "Recover"
          onActivated: root.recoverDraft(modelData)
          onButtonActivated: root.recoverDraft(modelData)
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Dictation" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: root.recording ? "Recording" : "Dictation"
        detail: (root.host && root.host.serviceRunning ? "Session " + root.host.sessionState : "Mouthtype is not running")
          + " · " + (!root.host ? "" : root.host.config.delivery_mode === "paste" ? "pasted into the active window" : root.host.config.delivery_mode === "type" ? "guarded typing" : "saved locally")
        DesignPrimaryButton {
          visible: !root.recording
          text: "Start Dictation"
          enabled: root.idle
          onActivated: root.host.run(["start"])
        }
        DesignSecondaryButton {
          visible: root.recording
          text: "Cancel"
          onActivated: root.host.run(["cancel"])
        }
        DesignPrimaryButton {
          visible: root.recording
          text: "Stop Dictation"
          onActivated: root.host.run(["stop"])
        }
      }
      DesignRow {
        title: root.host ? root.host.wordsToday + (root.host.wordsToday === 1 ? " word today" : " words today") : ""
        detail: "Counted from the takes Mouthtype still has."
        DesignSecondaryButton {
          text: "Copy Last"
          enabled: !!root.host && root.host.hasTranscript
          onActivated: root.host.run(["copy"])
        }
        DesignSecondaryButton {
          text: "Paste Last"
          enabled: root.canDeliver
          onActivated: { root.host.close(); Qt.callLater(function() { root.host.run(["paste-last"]) }) }
        }
      }
      DesignRow {
        visible: !!root.host && root.host.canImportFiles
        title: "Transcribe Audio File"
        detail: root.host && root.host.importActive ? "Working on a file now."
          : root.host && root.host.importHasResult ? "A file transcript is ready."
          : "Turn a WAV, AIFF or M4A file into text."
        clickable: true
        onActivated: root.openImport()
        DesignSecondaryButton {
          text: root.host && (root.host.importActive || root.host.importHasResult) ? "View" : "Choose File…"
          enabled: !!root.host && (root.host.importActive || root.host.importHasResult || root.idle)
          onActivated: root.openImport()
        }
      }
    }
  }

  function openImport() {
    if (!host) return
    if (host.importActive || host.importHasResult) host.openPage("import")
    else host.run(["import-pick"])
  }

  Repeater {
    model: root.groups
    delegate: Column {
      id: group
      required property var modelData
      width: root.width
      spacing: 6
      DesignEyebrow { text: group.modelData.label }
      DesignCard {
        width: parent.width
        Repeater {
          model: group.modelData.items
          delegate: HomeRow {
            id: take
            required property var modelData
            readonly property bool retry: modelData.retry
            title: retry ? "No transcript. The audio is saved." : (modelData.entry.preview || "Empty dictation")
            detail: Qt.formatTime(new Date((modelData.entry.mtime || 0) * 1000), "h:mm AP")
            buttonText: retry ? "Recover" : "Copy"
            onActivated: if (!retry) root.host.showRecording(modelData.entry.id)
            onButtonActivated: retry ? root.host.run(["transcribe", modelData.entry.id]) : root.host.run(["copy", modelData.entry.id])
          }
        }
      }
    }
  }

  DesignCard {
    visible: root.groups.length === 0
    width: parent.width
    DesignRow {
      title: "No dictations yet"
      detail: "Start a dictation and it shows up here."
    }
  }
}
