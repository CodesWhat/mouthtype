import QtQuick
import "design"

// The style the menu parts (ControlButton, MenuRow, MenuDivider) read. This default draws from the shared Theme so the parts
// load anywhere. A host can pass any object with the same shape, as ShellMenuStyle.qml does for the Omarchy shell.
QtObject {
  property color accent: Theme.accent
  property color mutedBackground: Theme.surface
  property color foreground: Theme.onAccent
  property var font: ({ family: "sans-serif", body: 13, bodySmall: 12, title: 16 })
  function space(n) { return n }
}
