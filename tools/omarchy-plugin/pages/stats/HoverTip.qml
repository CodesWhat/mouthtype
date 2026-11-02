import QtQuick
import "../../design"

// A quiet tooltip over its parent: an ink pill that shows after the pointer rests for half a second. It takes no input itself.
// The owner attaches the HoverHandler to its own item and passes `hovered` and `point` in, so no item here accepts hover events
// and controls underneath keep theirs.
Item {
  id: root

  property string text: ""
  property bool hovered: false
  property point point: Qt.point(0, 0)
  property bool armed: false

  anchors.fill: parent
  z: 50

  onHoveredChanged: if (!hovered) armed = false

  Timer {
    interval: 500
    running: root.hovered && root.text !== ""
    onTriggered: root.armed = true
  }

  Rectangle {
    visible: root.armed && root.hovered && root.text !== ""
    x: Math.max(0, Math.min(root.width - width, root.point.x + 12))
    y: Math.min(root.point.y + 18, Math.max(0, root.height - height))
    width: label.width + 16
    height: label.height + 8
    radius: 6
    color: Theme.ink

    Text {
      id: label
      x: 8
      y: 4
      width: Math.min(280, implicitWidth)
      text: root.text
      wrapMode: Text.Wrap
      color: Theme.bg
      font: Type.sans(11)
    }
  }
}
