import QtQuick
import "design"
import "parts"

// The dictation shortcut recorder, a nested modal over everything. The key-capture logic is the old panel's, moved here
// unchanged: it maps Qt key events to Hyprland key names, and a modifier pressed and released alone becomes the key.
Item {
  id: root

  property var host: null
  property bool open: false
  property bool capturing: false
  property string draft: ""
  property string pendingModifier: ""
  readonly property bool editing: capturing || draftField.activeFocus
  signal closeRequested()

  visible: open
  anchors.fill: parent

  onOpenChanged: {
    capturing = false
    pendingModifier = ""
    if (open) draft = host ? String(host.shortcutKeys || "") : ""
  }

  function beginCapture() {
    draft = host ? String(host.shortcutKeys || "") : draft
    capturing = true
    pendingModifier = ""
    capture.forceActiveFocus()
  }

  function hyprlandKeyName(event) {
    var k = event.key
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(65 + (k - Qt.Key_A))
    if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(48 + (k - Qt.Key_0))
    if (k >= Qt.Key_F1 && k <= Qt.Key_F24) return "F" + (1 + (k - Qt.Key_F1))
    var named = {}
    named[Qt.Key_Space] = "space"; named[Qt.Key_Return] = "Return"; named[Qt.Key_Enter] = "Return"; named[Qt.Key_Tab] = "Tab"
    named[Qt.Key_Backspace] = "BackSpace"; named[Qt.Key_Delete] = "Delete"; named[Qt.Key_Insert] = "Insert"; named[Qt.Key_Home] = "Home"
    named[Qt.Key_End] = "End"; named[Qt.Key_PageUp] = "Page_Up"; named[Qt.Key_PageDown] = "Page_Down"; named[Qt.Key_Print] = "Print"
    named[Qt.Key_Pause] = "Pause"; named[Qt.Key_ScrollLock] = "Scroll_Lock"; named[Qt.Key_Menu] = "Menu"; named[Qt.Key_Up] = "Up"
    named[Qt.Key_Down] = "Down"; named[Qt.Key_Left] = "Left"; named[Qt.Key_Right] = "Right"; named[Qt.Key_QuoteLeft] = "grave"
    named[Qt.Key_Minus] = "minus"; named[Qt.Key_Equal] = "equal"; named[Qt.Key_BracketLeft] = "bracketleft"; named[Qt.Key_BracketRight] = "bracketright"
    named[Qt.Key_Semicolon] = "semicolon"; named[Qt.Key_Apostrophe] = "apostrophe"; named[Qt.Key_Comma] = "comma"; named[Qt.Key_Period] = "period"
    named[Qt.Key_Slash] = "slash"; named[Qt.Key_Backslash] = "backslash"
    return named[k] || ""
  }

  // Left/right modifier keysyms by evdev scan code (X keycode), so a bare Right Control can be chosen.
  function modifierKeysym(event) {
    var byCode = { 37: "Control_L", 105: "Control_R", 50: "Shift_L", 62: "Shift_R", 64: "Alt_L", 108: "Alt_R", 133: "Super_L", 134: "Super_R" }
    if (byCode[event.nativeScanCode]) return byCode[event.nativeScanCode]
    if (event.key === Qt.Key_Control) return "Control_L"
    if (event.key === Qt.Key_Shift) return "Shift_L"
    if (event.key === Qt.Key_Alt) return "Alt_L"
    if (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L) return "Super_L"
    if (event.key === Qt.Key_Super_R) return "Super_R"
    return ""
  }

  function releaseShortcut(event) {
    if (!capturing) return
    var keysym = modifierKeysym(event)
    if (keysym !== "" && pendingModifier === keysym) {
      // A modifier pressed and released on its own becomes the key, with its own modifier implied.
      var mod = keysym.indexOf("Control") === 0 ? "CTRL" : keysym.indexOf("Shift") === 0 ? "SHIFT" : keysym.indexOf("Alt") === 0 ? "ALT" : "SUPER"
      draft = mod + " + " + keysym
      capturing = false
    }
    pendingModifier = ""
    event.accepted = true
  }

  function captureShortcut(event) {
    if (event.isAutoRepeat) { event.accepted = true; return }
    if (event.key === Qt.Key_Escape) { capturing = false; pendingModifier = ""; event.accepted = true; return }
    var keysym = modifierKeysym(event)
    if (keysym !== "") { pendingModifier = keysym; event.accepted = true; return }
    if (event.key === Qt.Key_AltGr || event.key === Qt.Key_CapsLock) { event.accepted = true; return }
    pendingModifier = ""
    var name = hyprlandKeyName(event)
    if (name === "") { event.accepted = true; return }
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    parts.push(name)
    draft = parts.join(" + ")
    capturing = false
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.scrim
    MouseArea { anchors.fill: parent; onClicked: root.closeRequested() }
  }

  Rectangle {
    id: sheet
    anchors.centerIn: parent
    width: Math.min(560, parent.width - 40)
    height: Math.min(content.implicitHeight + 56, parent.height - 40)
    radius: 14
    color: Theme.bg
    border.width: 1
    border.color: Theme.hair
    clip: true

    MouseArea { anchors.fill: parent }

    Flickable {
      anchors.fill: parent
      anchors.margins: 28
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick

      Column {
        id: content
        width: parent.width
        spacing: 16

        DesignPageHeader {
          width: parent.width
          title: "Dictation shortcut"
          summary: root.host && root.host.shortcutMode !== "off"
            ? (root.host.shortcutMode === "hold" ? "Hold to talk" : "Press to toggle") + " is on."
            : "No shortcut is set."
          titleSize: 24
          DesignKbd { visible: !!root.host && root.host.shortcutMode !== "off"; text: root.host ? root.host.shortcutKeys : "" }
        }

        Column {
          width: parent.width
          spacing: 6
          DesignEyebrow { text: "Choose the key" }
          DesignCard {
            width: parent.width
            DesignRow {
              title: root.capturing ? "Press the keys now" : "Record a key combination"
              detail: root.capturing ? "Esc cancels." : "Click, then press the keys you want."
              DesignKbd { visible: root.draft !== ""; text: root.draft }
              DesignPrimaryButton {
                text: root.capturing ? "Cancel" : "Record…"
                onActivated: { root.capturing = !root.capturing; root.pendingModifier = ""; if (root.capturing) capture.forceActiveFocus() }
              }
            }
            DesignRow {
              title: "Or type it"
              detail: "For example SUPER + SHIFT + D, F8 or Insert."
              FieldBox {
                id: draftField
                width: 200
                ring: root.capturing
                text: root.draft
                onTextEdited: root.draft = text
                hint: "SUPER + SHIFT + D"
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: 6
          DesignEyebrow { text: "A modifier key on its own" }
          Flow {
            width: parent.width
            spacing: 6
            Repeater {
              model: [["Right Ctrl", "CTRL + Control_R"], ["Left Ctrl", "CTRL + Control_L"], ["Right Alt", "ALT + Alt_R"], ["Left Alt", "ALT + Alt_L"],
                      ["Right Shift", "SHIFT + Shift_R"], ["Left Shift", "SHIFT + Shift_L"], ["Right Super", "SUPER + Super_R"], ["Left Super", "SUPER + Super_L"]]
              delegate: DesignSecondaryButton {
                required property var modelData
                text: modelData[0]
                enabled: root.draft !== modelData[1]
                onActivated: { root.capturing = false; root.draft = modelData[1] }
              }
            }
          }
        }

        Flow {
          width: parent.width
          spacing: 8
          DesignPrimaryButton {
            text: "Use for press-to-toggle"
            enabled: root.draft.trim() !== ""
            onActivated: if (root.host) root.host.run(["set-shortcut", "toggle", root.draft.trim()])
          }
          DesignPrimaryButton {
            text: "Use for hold-to-talk"
            enabled: root.draft.trim() !== ""
            onActivated: if (root.host) root.host.run(["set-shortcut", "hold", root.draft.trim()])
          }
          DesignSecondaryButton {
            text: "Turn the shortcut off"
            enabled: !!root.host && root.host.shortcutMode !== "off"
            onActivated: if (root.host) root.host.run(["set-shortcut", "off"])
          }
          DesignSecondaryButton { text: "Done"; onActivated: root.closeRequested() }
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          color: Theme.ink2
          font: Type.sans(Type.caption)
          text: "Letters, digits, F-keys, named keys such as Insert or Page_Down, or a modifier key on its own, with optional SUPER, ALT, CTRL or SHIFT. Modifier keys pressed alone are not delivered to applications on desktops with an input method such as fcitx5, so choose them with the buttons or type them. A key Hyprland already binds is refused. A lone modifier also fires inside its own shortcuts: Right Ctrl as hold-to-talk will start and stop a take whenever you use Right Ctrl for Ctrl+C."
        }
      }
    }

    Item {
      id: capture
      width: 1
      height: 1
      focus: root.capturing
      Keys.onPressed: function(event) { root.captureShortcut(event) }
      Keys.onReleased: function(event) { root.releaseShortcut(event) }
      onActiveFocusChanged: if (root.capturing && !activeFocus) forceActiveFocus()
    }
  }
}
