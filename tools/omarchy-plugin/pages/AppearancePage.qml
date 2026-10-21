import QtQuick
import "../design"
import "../parts"

// Appearance: the floating pill (show, style, size) and the text font Mouthtype uses for transcript cards and the Classic pill.
// Same set-pill and set-font verbs as the old Floating Pill and Text Font pages. The window's own chrome uses the bundled
// fonts, so the Menu role is not offered here. Readout colour is Mac Hi-Fi only and has no Linux setting.
Column {
  id: root

  property var host: null
  property string overrideRole: "transcript"
  property string familyDraft: ""
  property string overrideDraft: ""
  readonly property bool editing: familyField.activeFocus || overrideField.activeFocus
  readonly property var prefs: host ? host.fontPrefs : ({ preset: "default", family: "", overrides: {} })
  readonly property var pill: host ? host.pillPrefs : ({ enabled: true, skin: "classic", size: 1 })
  readonly property var presets: ["default", "sans", "serif", "mono", "custom"]
  readonly property var roles: ["transcript", "pill"]

  width: parent ? parent.width : 520
  spacing: 18

  function syncDrafts() {
    familyDraft = String(prefs.family || "")
    overrideDraft = String((prefs.overrides || {})[overrideRole] || "")
  }
  Component.onCompleted: syncDrafts()
  onPrefsChanged: if (!editing) syncDrafts()

  DesignPageHeader {
    width: parent.width
    title: "Appearance"
    summary: "The pill that floats while you dictate, and the text font Mouthtype uses."
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Floating pill" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Show the pill while dictating"
        detail: "A level meter with cancel and stop, a wave while transcribing, then a short note."
        StateSwitch {
          value: root.pill.enabled !== false
          text: "Show the pill while dictating"
          onToggled: root.host.run(["set-pill", "enabled", checked ? "on" : "off"])
        }
      }
      DesignRow {
        title: "Style"
        detail: "Classic is a capsule. Hi-Fi is a small unit with a bitmap readout."
        StateSegmented {
          model: ["Classic", "Hi-Fi"]
          value: root.pill.skin === "hifi" ? 1 : 0
          text: "Pill style"
          onActivated: function(index) { root.host.run(["set-pill", "skin", index === 1 ? "hifi" : "classic"]) }
        }
      }
      DesignRow {
        visible: root.pill.skin === "hifi"
        title: "Pill size"
        StateSegmented {
          model: ["Standard", "Large 2×"]
          value: root.pill.size === 2 ? 1 : 0
          text: "Pill size"
          onActivated: function(index) { root.host.run(["set-pill", "size", index === 1 ? "2" : "1"]) }
        }
      }
    }
    Text {
      width: parent.width
      leftPadding: 4
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      text: "The pill never takes keyboard focus; only its two buttons are clickable."
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Text font" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Text font"
        detail: "For transcript cards and the Classic pill. The Hi-Fi pill keeps its bitmap readout."
        StatePopup {
          model: ["Default", "Sans", "Serif", "Mono", "Custom family"]
          value: Math.max(0, root.presets.indexOf(root.prefs.preset || "default"))
          text: "Text font"
          onActivated: function(index) {
            if (root.presets[index] !== "custom") root.host.run(["set-font", "preset", root.presets[index]])
            else if (root.familyDraft.trim() !== "") root.host.run(["set-font", "family", root.familyDraft.trim()])
          }
        }
      }
      DesignRow {
        title: "Custom family"
        detail: "Any family fontconfig knows, for example Inter or Iosevka."
        FieldBox {
          id: familyField
          width: 180
          text: root.familyDraft
          hint: "Inter, Noto Serif"
          onTextEdited: root.familyDraft = text
          onAccepted: root.host.run(["set-font", "family", root.familyDraft.trim()])
        }
        DesignSecondaryButton {
          text: "Use"
          enabled: root.familyDraft.trim() !== ""
          onActivated: root.host.run(["set-font", "family", root.familyDraft.trim()])
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Override one role" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Role"
        detail: "Pick a family for just this part. Leave it blank to follow the font above."
        DesignSegmented {
          model: ["Transcript", "Pill"]
          currentIndex: root.roles.indexOf(root.overrideRole)
          text: "Font role"
          onActivated: function(index) {
            root.overrideRole = root.roles[index]
            root.overrideDraft = String((root.prefs.overrides || {})[root.overrideRole] || "")
          }
        }
      }
      DesignRow {
        title: "Family for " + root.overrideRole
        FieldBox {
          id: overrideField
          width: 180
          text: root.overrideDraft
          hint: "Follow the preset"
          onTextEdited: root.overrideDraft = text
          onAccepted: root.host.run(["set-font", "override", root.overrideRole, root.overrideDraft.trim() || "-"])
        }
        DesignSecondaryButton {
          text: "Apply"
          onActivated: root.host.run(["set-font", "override", root.overrideRole, root.overrideDraft.trim() || "-"])
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Preview" }
    DesignCard {
      width: parent.width
      Item {
        width: parent.width
        height: previewColumn.height + 32
        Column {
          id: previewColumn
          x: 16
          y: 16
          width: parent.width - 32
          spacing: 10
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Transcript · The quick brown fox jumps over the lazy dog."
            color: Theme.ink
            font.family: root.host ? root.host.transcriptFont : Type.sansFamily
            font.pixelSize: Type.body
          }
          Rectangle {
            width: pillText.implicitWidth + 32
            height: 28
            radius: 14
            color: Qt.rgba(0x1A / 255, 0x1A / 255, 0x1A / 255, 0.96)
            border.width: 1
            border.color: "#4D4A42"
            Text {
              id: pillText
              anchors.centerIn: parent
              text: "Pill · Pasted"
              color: "#FFFFEB"
              font.family: root.host ? root.host.pillFont : Type.sansFamily
              font.pixelSize: 13
              font.weight: Font.Medium
            }
          }
        }
      }
    }
  }
}
