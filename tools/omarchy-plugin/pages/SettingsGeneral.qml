import QtQuick
import "../design"
import "../parts"

// Settings, General: shortcut, recording behaviour and length, where the text goes, sounds and desktop cues.
// Moved from the old Recording Settings, Paste Options and shortcut pages with the same verbs. Live words
// and quiet other audio have no Linux setting yet, so they are not listed.
Column {
  id: root

  property var host: null
  property string classDraft: ""
  readonly property bool editing: classField.activeFocus
  readonly property var config: host ? host.config : ({})
  readonly property string mode: host ? host.shortcutMode : "off"
  readonly property var lengths: [30, 60, 120]
  readonly property var mics: host && host.microphoneInfo ? host.microphoneInfo : ({ sources: [], selected: "default" })
  readonly property var micNames: ["default"].concat(mics.sources.map(function(item) { return item.name }))
  readonly property var micLabels: ["System default"].concat(mics.sources.map(function(item) { return item.description }))
  readonly property var level: host ? host.micLevel : null

  width: parent ? parent.width : 520
  spacing: 18

  function syncClass() {
    if (!classField.activeFocus) classDraft = config.allowed_classes && config.allowed_classes.length ? config.allowed_classes[0] : ""
  }
  onConfigChanged: syncClass()
  Component.onCompleted: { syncClass(); if (host) host.loadMicrophones() }

  function setMode(index) {
    if (index === 0) host.run(["set-shortcut", "off"])
    else if (index === 1) host.run(["set-shortcut", "hold", host.shortcutKeys || "F10"])
    else host.run(["set-shortcut", "toggle", host.shortcutKeys || "SUPER + ALT + M"])
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Dictation" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Shortcut"
        detail: root.mode === "off" ? "No shortcut is set." : root.mode === "hold" ? "Hold it, speak, let go." : "Press once to start, again to stop."
        DesignKbd { visible: root.mode !== "off"; text: root.host ? root.host.shortcutKeys : "" }
        DesignSecondaryButton { text: "Change…"; onActivated: root.host.openPage("shortcut") }
      }
      DesignRow {
        title: "Recording behavior"
        detail: "Hold to talk, or press once to start and again to stop."
        StatePopup {
          model: ["Off", "Hold to talk", "Press to toggle"]
          value: root.mode === "hold" ? 1 : root.mode === "toggle" ? 2 : 0
          text: "Recording behavior"
          onActivated: function(index) { root.setMode(index) }
        }
      }
      DesignRow {
        title: "Microphone"
        detail: root.mics.missing
          ? "The chosen microphone is not connected, so recording uses the system default."
          : root.mics.muted === true && root.mics.selected === "default" ? "The default microphone is muted." : "Which input Mouthtype records from."
        StatePopup {
          model: root.micLabels
          value: Math.max(0, root.micNames.indexOf(root.mics.selected))
          text: "Microphone"
          onActivated: function(index) { root.host.run(["set-config", "microphone", root.micNames[index]]) }
        }
      }
      DesignRow {
        title: "Test microphone"
        detail: root.host && root.host.micTesting ? "Listening for two seconds. Say something."
          : root.level ? (root.level.peak < 0.01 ? "Nothing heard. Check the microphone is plugged in and not muted." : "Heard you. Peak " + Math.round(root.level.peak * 100) + "%.")
          : "Records two seconds, shows the level, and keeps nothing."
        Rectangle {
          width: 80; height: 6; radius: 3; anchors.verticalCenter: parent.verticalCenter; color: Theme.hair2
          Rectangle { width: parent.width * (root.level ? Math.min(1, root.level.peak) : 0); height: parent.height; radius: 3; color: Theme.accent }
        }
        DesignSecondaryButton { text: "Test"; enabled: !!root.host && !root.host.micTesting; onActivated: root.host.testMicrophone() }
      }
      DesignRow {
        title: "Recording length"
        detail: "A take stops by itself at this limit."
        StatePopup {
          model: ["30 seconds", "60 seconds", "120 seconds"]
          value: Math.max(0, root.lengths.indexOf(root.config.maximum_recording_seconds))
          text: "Recording length"
          onActivated: function(index) { root.host.run(["set-config", "maximum_recording_seconds", String(root.lengths[index])]) }
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Where the text goes" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Delivery"
        detail: root.config.delivery_mode === "type"
          ? "Typing into one app. Choosing another option turns that off."
          : "Paste puts the text in the window that was active when you started speaking, then restores your clipboard. Terminals get Ctrl+Shift+V and no multi-line pastes."
        StatePopup {
          model: ["Save to recovery only", "Paste into the active window"]
          value: root.config.delivery_mode === "paste" ? 1 : 0
          text: "Delivery"
          onActivated: function(index) { root.host.run(["set-config", "delivery", index === 1 ? "paste" : "recover"]) }
        }
      }
      DesignRow {
        title: "Type into one allowed app"
        detail: root.config.delivery_mode === "type" ? "On. Typing goes only to this exact Hyprland window class." : "Enter the exact Hyprland window class."
        FieldBox {
          id: classField
          width: 190
          text: root.classDraft
          hint: "org.gnome.TextEditor"
          onTextEdited: root.classDraft = text
        }
        DesignSecondaryButton {
          text: "Enable"
          enabled: root.classDraft.trim() !== ""
          onActivated: root.host.run(["set-config", "delivery", "type", root.classDraft.trim()])
        }
      }
    }
    Text {
      width: parent.width
      leftPadding: 4
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      text: "Linux cannot detect password fields, so pasting and typing go wherever the cursor is. Type delivery is limited to the exact app class and single-line text; check the target before retrying an uncertain insertion."
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "While recording" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Recording sounds"
        detail: "A small cue when you start and finish."
        StateSwitch {
          value: !!root.host && root.host.soundsEnabled
          text: "Recording sounds"
          onToggled: root.host.run(["set-sounds", checked ? "on" : "off"])
        }
      }
      DesignRow {
        title: "Desktop recording cues"
        detail: "A desktop notification when recording starts and stops."
        StateSwitch {
          value: root.config.notifications !== false
          text: "Desktop recording cues"
          onToggled: root.host.run(["set-config", "notifications", checked ? "on" : "off"])
        }
      }
    }
  }
}
