import QtQuick
import qs.Commons

// Maps Omarchy's Style and Color singletons onto the shape MenuStyle defines, so the menu parts look the same in the shell.
QtObject {
  readonly property color accent: Color.accent
  readonly property color mutedBackground: Color.popups.background
  readonly property color foreground: Color.foreground
  readonly property var font: Style.font
  function space(n) { return Style.space(n) }
}
