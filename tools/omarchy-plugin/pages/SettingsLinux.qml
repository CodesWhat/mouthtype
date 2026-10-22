import QtQuick
import "../design"
import "../parts"

// Settings, Linux: what the Mac's own page held, translated. Launch at login is the systemd user unit control.py manages,
// updates come from the package manager, and the keyboard notes explain Hyprland shortcut behaviour.
Column {
  id: root

  property var host: null

  width: parent ? parent.width : 520
  spacing: 18

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Login" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Launch at login"
        detail: "Start the Mouthtype service when your graphical session starts."
        StateSwitch {
          value: !!root.host && root.host.autostartEnabled
          text: "Launch at login"
          onToggled: root.host.run(["set-autostart", checked ? "on" : "off"])
        }
      }
      DesignRow {
        title: "Updates"
        detail: "Mouthtype does not update itself on Linux. Update it with your package manager or by reinstalling the plugin."
      }
      DesignRow {
        title: "Mouthtype service"
        detail: root.host && root.host.serviceRunning ? "Running." : "Not running."
        DesignSecondaryButton {
          text: "Quit Mouthtype"
          enabled: !!root.host && root.host.serviceRunning
          onActivated: root.host.run(["shutdown"])
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 6
    DesignEyebrow { text: "Keyboard" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Shortcuts are Hyprland bindings"
        detail: "Mouthtype writes the binding into your Hyprland config. A key Hyprland already binds is refused."
      }
      DesignRow {
        title: "Modifier keys on their own"
        detail: "Right Ctrl as hold-to-talk starts and stops a take whenever you use Right Ctrl for Ctrl+C. On desktops with an input method such as fcitx5, a lone modifier is not delivered to applications."
      }
    }
  }
}
