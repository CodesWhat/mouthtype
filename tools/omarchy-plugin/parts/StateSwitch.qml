import QtQuick
import "../design"

// A DesignSwitch that follows `value` (the daemon's answer) instead of staying where the click left it. Listen to `toggled`
// to send the change; the switch settles on whatever `value` says next.
DesignSwitch {
  id: root

  property bool value: false

  Binding { target: root; property: "checked"; value: root.value }
}
