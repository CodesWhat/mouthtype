import QtQuick
import "../design"

// A DesignSegmented that follows `value`, the index the daemon reports. Listen to `activated` to send the change.
DesignSegmented {
  id: root

  property int value: 0

  Binding { target: root; property: "currentIndex"; value: root.value }
}
