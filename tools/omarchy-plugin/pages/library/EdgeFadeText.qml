import QtQuick
import "../../design"

// One line of text, clipped at the right edge with a fade into `fadeColor` instead of an ellipsis. The Text itself is only as
// wide as this item, so it never reports a width past its parent.
Item {
  id: root

  property string text: ""
  property font font: Type.sans(Type.body)
  property color color: Theme.ink
  property color fadeColor: Theme.surface
  property real fadeWidth: 28
  readonly property bool overflowing: label.implicitWidth > width + 0.5
  readonly property real naturalWidth: label.implicitWidth

  implicitHeight: label.implicitHeight
  height: implicitHeight
  clip: true

  Text {
    id: label
    width: parent.width
    text: root.text
    font: root.font
    color: root.color
    wrapMode: Text.NoWrap
    clip: true
  }

  Rectangle {
    visible: root.overflowing
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Math.min(root.fadeWidth, root.width)
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: Qt.rgba(root.fadeColor.r, root.fadeColor.g, root.fadeColor.b, 0) }
      GradientStop { position: 1; color: root.fadeColor }
    }
  }
}
