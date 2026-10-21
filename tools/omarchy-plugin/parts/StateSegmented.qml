import QtQuick
import "../design"

// A DesignSegmented that follows `value`, the index the daemon reports. Listen to `activated` to send the change.
DesignSegmented {
  id: root

  property int value: 0

  Binding { target: root; property: "currentIndex"; value: root.value }

  // If the daemon refuses a change the value never moves, so settle back on it once the action has had time to finish.
  Timer { id: settle; interval: 2000; onTriggered: root.currentIndex = root.value }
  Connections { target: root; function onActivated() { settle.restart() } }
}
