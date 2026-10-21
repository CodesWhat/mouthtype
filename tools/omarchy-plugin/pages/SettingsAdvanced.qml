import QtQuick
import "../design"
import "../parts"

// Settings, Advanced: history retention. Shown while the Advanced options switch is on. Moved from the old Dictation History
// page with the same set-config keys.
Column {
  id: root

  property var host: null
  readonly property var config: host ? host.config : ({})
  readonly property var keepValues: ["off", "5", "20", "50"]
  readonly property var limitValues: ["100", "200", "500", "1000"]
  readonly property var audioValues: ["14", "30", "90", "none"]

  width: parent ? parent.width : 520
  spacing: 18

  function indexOfValue(list, value) {
    var at = list.indexOf(String(value))
    return at < 0 ? 0 : at
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "History" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Automatically keep only the newest"
        detail: "Everything older is forgotten after each dictation."
        StateSegmented {
          model: ["Keep all", "5", "20", "50"]
          value: root.indexOfValue(root.keepValues, root.config.history_keep === null || root.config.history_keep === undefined ? "off" : root.config.history_keep)
          text: "Keep only the newest"
          onActivated: function(index) { root.host.run(["set-config", "history_keep", root.keepValues[index]]) }
        }
      }
      DesignRow {
        title: "History limit"
        detail: "With Keep all, recording stops at this limit instead of deleting anything."
        StateSegmented {
          model: ["100", "200", "500", "1000"]
          value: root.indexOfValue(root.limitValues, root.config.maximum_recovery_takes || 200)
          text: "History limit"
          onActivated: function(index) { root.host.run(["set-config", "maximum_recovery_takes", root.limitValues[index]]) }
        }
      }
      DesignRow {
        title: "Keep finished audio for"
        detail: "Older audio, or anything beyond 2 GB, is removed. The text stays."
        StateSegmented {
          model: ["14 days", "30 days", "90 days", "No limit"]
          value: root.indexOfValue(root.audioValues, root.config.audio_retention_days === null || root.config.audio_retention_days === undefined ? "none" : root.config.audio_retention_days)
          text: "Keep finished audio for"
          onActivated: function(index) { root.host.run(["set-config", "audio_retention_days", root.audioValues[index]]) }
        }
      }
    }
  }
}
