import QtQuick
import "../design"
import "../parts"

// Settings, Health: service status, cleanup models and their setup, history, and About with both versions.
// The cleanup level is chosen on the Style page, Cleanup tab. The model status and Prepare rows stay here.
Column {
  id: root

  property var host: null
  readonly property var config: host ? host.config : ({})
  readonly property var models: host && host.cleanupInfo.models ? host.cleanupInfo.models : ({})
  readonly property var setup: host && host.cleanupInfo.setup ? host.cleanupInfo.setup : null
  readonly property var service: host && host.cleanupInfo.service ? host.cleanupInfo.service : null
  readonly property bool setupActive: !!setup && (setup.state === "preparing" || setup.state === "building" || setup.state === "downloading")
  readonly property var history: host ? host.history : ({ takes: 0, maximum: 200 })
  readonly property var versions: host && host.versions ? host.versions : ({})
  readonly property string level: config.cleanup === "basic" || config.cleanup === "fast" || config.cleanup === "thorough" ? config.cleanup : "off"

  width: parent ? parent.width : 520
  spacing: 18

  function modelDetail(level) {
    if (service && service.level === level && service.model) {
      var s = service.model.state
      if (s === "ready") return "Ready"
      if (s === "loading") return "Loading…"
      if (s === "failed") return "Failed"
    }
    if (models[level] === "prepared") return "Prepared"
    return "Not prepared"
  }

  function setupText() {
    if (!setup) return ""
    if (setup.state === "building") return "Building the pinned llama.cpp server…"
    if (setup.state === "downloading") return "Downloading and verifying the " + (setup.level || "") + " model…"
    if (setup.state === "preparing") return "Preparing…"
    if (setup.state === "failed") return "Preparation failed (" + (setup.error || "error") + "). Check the cleanup setup log."
    return ""
  }

  readonly property bool sized: !!setup && setup.state === "downloading" && setup.bytes_total > 0
  readonly property real fraction: sized ? Math.min(1, Math.max(0, setup.bytes_done / setup.bytes_total)) : 0

  function megabytes(bytes) {
    return Math.round(bytes / 1000000) + " MB"
  }

  function lastTake() {
    if (!service || !service.last_outcome || (level !== "fast" && level !== "thorough")) return ""
    var outcome = service.last_outcome
    var text = outcome === "ok" ? "model text accepted" : outcome === "guard-rejected" ? "kept Basic (guard)"
      : outcome === "timeout" ? "kept Basic (over budget)" : outcome === "skipped" ? "model skipped" : "kept Basic (model error)"
    var ms = service.last_ms !== null && service.last_ms !== undefined ? " · " + service.last_ms + " ms" : ""
    return "Last take: " + text + ms
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Status" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Session"
        detail: root.host && root.host.serviceRunning ? root.host.sessionState : "off"
      }
      DesignRow {
        title: "Speech model"
        detail: "Parakeet TDT 0.6B v3"
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Cleanup" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Cleanup level: " + (root.level === "off" ? "Off" : root.level === "basic" ? "Basic" : root.level === "fast" ? "Fast" : "Thorough")
        detail: "Choose it on the Style page, under Cleanup."
        DesignSecondaryButton { text: "Open Style"; onActivated: root.host.openPage("style") }
      }
      DesignRow {
        title: "Fast model"
        detail: root.modelDetail("fast")
      }
      DesignRow {
        title: "Thorough model"
        detail: root.modelDetail("thorough")
      }
    }
    DesignCard {
      width: parent.width
      visible: root.models.fast !== "prepared" || root.models.thorough !== "prepared"
      DesignRow {
        visible: root.models.fast !== "prepared"
        title: "Prepare Fast cleanup"
        detail: "About 480 MB."
        DesignSecondaryButton { text: "Prepare…"; enabled: !root.setupActive; onActivated: root.host.run(["cleanup-setup", "fast"]) }
      }
      DesignRow {
        visible: root.models.thorough !== "prepared"
        title: "Prepare Thorough cleanup"
        detail: "About 2.5 GB."
        DesignSecondaryButton { text: "Prepare…"; enabled: !root.setupActive; onActivated: root.host.run(["cleanup-setup", "thorough"]) }
      }
    }
    Text {
      visible: text !== ""
      width: parent.width
      leftPadding: 4
      wrapMode: Text.Wrap
      color: root.setup && root.setup.state === "failed" ? Theme.danger : Theme.ink2
      font: Type.sans(Type.caption)
      text: root.setupText()
    }
    DesignProgress {
      objectName: "setupProgress"
      visible: root.sized
      width: parent.width
      value: root.fraction
    }
    Text {
      objectName: "setupBytes"
      visible: root.sized
      width: parent.width
      leftPadding: 4
      color: Theme.ink2
      font: Type.sans(Type.caption)
      text: root.sized ? root.megabytes(Math.min(root.setup.bytes_done || 0, root.setup.bytes_total)) + " of " + root.megabytes(root.setup.bytes_total) : ""
    }
    Text {
      visible: text !== ""
      width: parent.width
      leftPadding: 4
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      text: root.lastTake()
    }
    Text {
      width: parent.width
      leftPadding: 4
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      text: "Fast and Thorough are local llama.cpp models with the Mac guard rules. When a model times out or changes meaning, the Basic text is kept."
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "History" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: root.history.takes + " of " + root.history.maximum + " saved dictations" + (root.history.takes >= root.history.maximum ? " · full" : "")
        detail: root.host && root.host.savedCount > 0 ? root.host.savedCount + " with audio saved to retry. Recover them on Home." : ""
      }
      DesignRow {
        title: "Forget dictations older than 30 days"
        DesignSecondaryButton { text: "Forget"; enabled: root.history.takes > 0; onActivated: root.host.run(["prune", "older", "30"]) }
      }
      DesignRow {
        title: "Forget all but the newest 20"
        DesignSecondaryButton { text: "Forget"; enabled: root.history.takes > 20; onActivated: root.host.run(["prune", "keep", "20"]) }
      }
      DesignRow {
        title: "Forget all dictations"
        DesignSecondaryButton { text: "Forget all"; enabled: root.history.takes > 0; onActivated: root.host.run(["prune", "all", "0"]) }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "About" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Mouthtype for Linux"
        detail: "App version " + (root.versions.app || "unknown")
      }
      DesignRow {
        title: "Panel plugin"
        detail: "Plugin version " + (root.versions.plugin || "unknown")
      }
      DesignRow {
        title: "How to use"
        detail: "Press Start Dictation on Home, speak, then Stop. The text is saved under Recent takes. Use Recover on Home to retry audio after a speech error."
          + (root.host && root.host.canImportFiles ? " Transcribe Audio File turns one WAV, AIFF or M4A file into raw text you can copy or save." : "")
      }
    }
  }
}
