import QtQuick
import "../../design"

// A mono phrase on the c0 tint, radius 5. Grows with its text up to `maxWidth`, then clips with a fade.
Rectangle {
  id: root

  property string text: ""
  property real maxWidth: 150
  property real textSize: 11.5

  implicitWidth: Math.min(maxWidth, metrics.advanceWidth + 16)
  implicitHeight: label.implicitHeight + 6
  width: implicitWidth
  height: implicitHeight
  radius: 5
  color: Theme.c0

  TextMetrics {
    id: metrics
    font: Type.mono(root.textSize)
    text: root.text
  }

  EdgeFadeText {
    id: label
    x: 8
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width - 16
    text: root.text
    font: Type.mono(root.textSize)
    fadeColor: Theme.c0
    fadeWidth: 16
  }
}
