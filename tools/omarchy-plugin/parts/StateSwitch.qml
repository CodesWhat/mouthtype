import QtQuick
import "../design"

// A DesignSwitch that follows `value` (the daemon's answer) instead of staying where the click left it. Listen to `toggled`
// to send the change; the switch settles on whatever `value` says next.
DesignSwitch {
  id: root

  property bool value: false

  Binding { target: root; property: "checked"; value: root.value }

  // If the daemon refuses a change the value never moves, so settle back on it once the action has had time to finish.
  Timer { id: settle; interval: 2000; onTriggered: root.checked = root.value }
  Connections { target: root; function onToggled() { settle.restart() } }
}
