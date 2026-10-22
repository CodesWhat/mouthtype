import QtQuick
import "design"
import "parts"

// The Settings modal: a 760 by 540 sheet with its own nav (General, Linux, Health, and Advanced while the switch in the
// footer is on). Each tab is a file in pages/ that takes `host`. The shortcut recorder opens over this as another modal.
Item {
  id: root

  property var host: null
  property bool open: false
  property string tab: "general"
  property bool advanced: false
  readonly property bool editing: tabLoader.item ? tabLoader.item.editing === true : false
  signal closeRequested()
  signal tabRequested(string tab)
  signal advancedToggled(bool on)

  visible: open
  anchors.fill: parent

  readonly property var tabs: advanced
    ? [{ key: "general", title: "General", icon: "gear", summary: "Set your shortcut, how it records, and where the text goes." },
       { key: "linux", title: "Linux", icon: "linux-logo", summary: "Launch at login and the notes that only matter on Linux." },
       { key: "health", title: "Health", icon: "heartbeat", summary: "Cleanup models, history and what is installed." },
       { key: "advanced", title: "Advanced", icon: "sliders-horizontal", summary: "History limits and retention." }]
    : [{ key: "general", title: "General", icon: "gear", summary: "Set your shortcut, how it records, and where the text goes." },
       { key: "linux", title: "Linux", icon: "linux-logo", summary: "Launch at login and the notes that only matter on Linux." },
       { key: "health", title: "Health", icon: "heartbeat", summary: "Cleanup models, history and what is installed." }]

  function infoFor(key) {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].key === key) return tabs[i]
    return tabs[0]
  }
  readonly property var info: infoFor(tab)
  readonly property string appVersion: host && host.versions && host.versions.app ? String(host.versions.app) : ""

  Rectangle {
    anchors.fill: parent
    color: Theme.scrim
    MouseArea { anchors.fill: parent; onClicked: root.closeRequested() }
  }

  Rectangle {
    id: sheet
    anchors.centerIn: parent
    width: Math.min(760, parent.width - 40)
    height: Math.min(540, parent.height - 40)
    radius: 14
    color: Theme.bg
    border.width: 1
    border.color: Theme.hair
    clip: true

    MouseArea { anchors.fill: parent }

    Rectangle {
      id: nav
      width: 200
      height: parent.height
      color: Theme.sideBase

      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0; color: Theme.sideTop }
          GradientStop { position: 1; color: Theme.sideBottom }
        }
      }

      DesignEyebrow {
        x: 14
        y: 20
        width: parent.width - 28
        text: "Settings"
      }

      Column {
        x: 8
        y: 48
        width: parent.width - 16
        spacing: 2
        Repeater {
          model: root.tabs
          delegate: ModalNavRow {
            required property var modelData
            title: modelData.title
            iconName: modelData.icon
            selected: root.tab === modelData.key
            onActivated: root.tabRequested(modelData.key)
          }
        }
      }

      Rectangle {
        x: 12
        y: parent.height - 84
        width: parent.width - 24
        height: 1
        color: Theme.hair2
      }
      Text {
        x: 14
        y: parent.height - 70
        width: parent.width - 28 - 48
        text: "Advanced options"
        wrapMode: Text.Wrap
        color: Theme.ink
        font: Type.sans(Type.detail, "medium")
      }
      StateSwitch {
        x: parent.width - width - 14
        y: parent.height - 72
        compact: true
        value: root.advanced
        text: "Advanced options"
        onToggled: root.advancedToggled(checked)
      }
      DesignEyebrow {
        x: 14
        y: parent.height - 38
        width: parent.width - 28
        visible: root.appVersion !== ""
        text: "Mouthtype " + root.appVersion
      }
    }

    Item {
      id: pane
      x: nav.width
      width: parent.width - nav.width
      height: parent.height

      DesignPageHeader {
        id: header
        x: 24
        y: 24
        width: parent.width - 48 - 40
        title: root.info.title
        summary: root.info.summary
        titleSize: 24
      }

      Item {
        id: closeButton
        x: parent.width - 24 - 28
        y: 24
        width: 28
        height: 28
        activeFocusOnTab: true
        Rectangle {
          anchors.fill: parent
          radius: 14
          color: Theme.sel
        }
        Rectangle {
          anchors.fill: parent
          anchors.margins: -3
          radius: 17
          color: "transparent"
          border.width: 2
          border.color: Theme.focus
          visible: closeButton.activeFocus
        }
        Icon { anchors.centerIn: parent; name: "close"; size: 16; color: Theme.ink }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.closeRequested() }
        Keys.onSpacePressed: root.closeRequested()
        Keys.onReturnPressed: root.closeRequested()
        Accessible.role: Accessible.Button
        Accessible.name: "Close settings"
        Accessible.onPressAction: root.closeRequested()
      }

      Flickable {
        id: scroll
        x: 0
        y: header.y + header.height + 16
        width: parent.width
        height: parent.height - y
        contentWidth: width
        contentHeight: tabLoader.height + 32
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Loader {
          id: tabLoader
          x: 24
          width: scroll.width - 48
          height: item ? item.implicitHeight : 0
          source: root.open ? "pages/Settings" + root.tab.charAt(0).toUpperCase() + root.tab.slice(1) + ".qml" : ""
          onLoaded: if (item.host !== undefined) item.host = root.host
        }

        Text {
          visible: tabLoader.status === Loader.Error
          x: 24
          width: scroll.width - 48
          wrapMode: Text.Wrap
          color: Theme.ink2
          font: Type.sans(Type.body)
          text: "This settings page could not be loaded."
        }
      }
    }
  }
}
