import QtQuick
import "design"

// The window's one sidebar: Home, Stats, Dictionary, Transforms, Style, Appearance, then Settings pinned to the bottom. Selection
// is the sel tint only. `current` is the page key; `activated(key)` fires for the six pages and `settingsRequested()` for the gear.
Rectangle {
  id: root

  property string current: "home"
  property bool settingsOpen: false
  signal activated(string key)
  signal settingsRequested()

  readonly property var items: [
    { key: "home", title: "Home", icon: "house" },
    { key: "stats", title: "Stats", icon: "chart-bar" },
    { key: "dictionary", title: "Dictionary", icon: "book" },
    { key: "transforms", title: "Transforms", icon: "magic-wand" },
    { key: "style", title: "Style", icon: "text-aa" },
    { key: "appearance", title: "Appearance", icon: "pill" }
  ]

  implicitWidth: 220
  color: Theme.sideBase

  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0; color: Theme.sideTop }
      GradientStop { position: 1; color: Theme.sideBottom }
    }
  }

  Text {
    x: 22
    y: 22
    text: "mouthtype"
    color: Theme.ink
    font: Type.serif(Type.display)
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  Column {
    x: 8
    y: 74
    width: parent.width - 16
    spacing: 2

    Repeater {
      model: root.items
      delegate: DesignNavRow {
        required property var modelData
        title: modelData.title
        iconName: modelData.icon
        selected: root.current === modelData.key && !root.settingsOpen
        onActivated: root.activated(modelData.key)
      }
    }
  }

  DesignNavRow {
    x: 8
    y: parent.height - height - 12
    width: parent.width - 16
    title: "Settings"
    iconName: "gear"
    selected: root.settingsOpen
    onActivated: root.settingsRequested()
  }
}
