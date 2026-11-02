import QtQuick
import ".."

// Every shared component on one page. Rendered to PNG in light and dark by render_gallery.sh. Set `dark` to pin the mode.
Rectangle {
  id: root

  property bool dark: false

  width: 760
  height: 1000
  color: Theme.bg

  Binding { target: Theme; property: "forceDark"; value: root.dark }

  Row {
    anchors.fill: parent
    anchors.margins: 0

    // Sidebar column: nav rows, one selected.
    Rectangle {
      width: 200
      height: parent.height
      color: Theme.sideBase
      Column {
        x: 8
        y: 16
        width: parent.width - 16
        spacing: 2
        DesignNavRow { title: "Home"; iconName: "house" }
        DesignNavRow { title: "Stats"; iconName: "chart-bar"; selected: true }
        DesignNavRow { title: "Dictionary"; iconName: "book" }
        DesignNavRow { title: "Transforms"; iconName: "magic-wand" }
        DesignNavRow { title: "Style"; iconName: "text-aa" }
        DesignNavRow { title: "Appearance"; iconName: "pill" }
        DesignNavRow { title: "Settings"; iconName: "gear" }
      }
      Text {
        x: 18
        y: 330
        width: parent.width - 36
        wrapMode: Text.Wrap
        text: "Small text on the sidebar wash."
        color: Theme.sideInk
        font: Type.sans(Type.caption)
      }
    }

    Column {
      id: page
      x: 0
      width: 560
      leftPadding: 32
      topPadding: 32
      spacing: 18

      DesignPageHeader {
        width: 496
        title: "Component gallery"
        summary: "The shared pieces every Linux page builds on."
        DesignSecondaryButton { text: "Export" }
      }

      Column {
        spacing: 6
        DesignEyebrow { text: "General" }
        DesignCard {
          width: 496
          DesignRow {
            title: "Launch at login"
            detail: "Start Mouthtype when you sign in."
            DesignSwitch { checked: true; text: "Launch at login" }
          }
          DesignRow {
            title: "Show in the bar"
            DesignSwitch { checked: false; text: "Show in the bar" }
          }
          DesignRow {
            title: "Cleanup level"
            detail: "How much the transcript is tidied before it is pasted."
            clickable: true
            DesignPopup { model: ["Off", "Basic", "Fast", "Thorough"]; currentIndex: 2; text: "Cleanup level" }
          }
          DesignRow {
            title: "Appearance"
            clickable: true
            selected: true
            DesignSegmented { model: ["Light", "Dark", "System"]; currentIndex: 2; text: "Appearance" }
          }
        }
        Text {
          width: 496
          leftPadding: 4
          wrapMode: Text.Wrap
          text: "Footer note under a card. It wraps instead of truncating."
          color: Theme.ink2
          font: Type.sans(Type.caption)
        }
      }

      Column {
        spacing: 6
        DesignEyebrow { text: "Shortcut" }
        DesignCard {
          width: 496
          DesignRow {
            title: "Hold to talk"
            detail: "Press and hold, release to paste."
            Row {
              spacing: 4
              DesignKbd { text: "Super" }
              DesignKbd { text: "Space" }
            }
          }
          DesignRow {
            title: "A long title that has to wrap onto a second line because the controls leave it no room"
            detail: "And a detail line that also wraps when the card is narrow, so nothing is cut off."
            DesignPrimaryButton { text: "Record shortcut" }
            DesignSecondaryButton { text: "Reset" }
          }
        }
      }

      Column {
        spacing: 8
        DesignEyebrow { text: "Buttons" }
        Row {
          spacing: 8
          DesignPrimaryButton { text: "Primary" }
          DesignSecondaryButton { text: "Secondary" }
          DesignPrimaryButton { text: "Disabled"; enabled: false }
          DesignSecondaryButton { text: "Disabled"; enabled: false }
        }
      }

      Column {
        spacing: 8
        DesignEyebrow { text: "Icons" }
        Row {
          spacing: 14
          Repeater {
            model: ["close", "plus", "chevron-left", "chevron-right", "chevron-up", "chevron-down", "search", "copy", "flame", "check", "trash", "warning", "clock"]
            delegate: Icon { required property string modelData; name: modelData; size: 24; color: Theme.ink2 }
          }
        }
      }

      Column {
        spacing: 8
        DesignEyebrow { text: "Palette" }
        Row {
          spacing: 6
          Repeater {
            model: [Theme.c0, Theme.c1, Theme.c2, Theme.c3, Theme.c4, Theme.accent, Theme.orange, Theme.gold, Theme.silver, Theme.bronze]
            delegate: Rectangle { required property color modelData; width: 34; height: 34; radius: 6; color: modelData; border.width: 1; border.color: Theme.hair2 }
          }
        }
        Row {
          spacing: 12
          Text { text: "Serif 22"; color: Theme.ink; font: Type.serif(Type.display) }
          Text { text: "Sans 13 body"; color: Theme.ink; font: Type.sans(Type.body) }
          Text { text: "Sans 12 detail"; color: Theme.ink2; font: Type.sans(Type.detail) }
          Text { text: "caption 11.5"; color: Theme.ink2; font: Type.sans(Type.caption) }
        }
        Text { property bool axisLabel: true; text: "Axis label 9"; color: Theme.ink3; font: Type.axis }
      }
    }
  }
}
