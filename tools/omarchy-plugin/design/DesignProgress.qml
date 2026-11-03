import QtQuick

// Determinate progress bar: a hair2 track with an accent fill. `value` is 0 to 1 and is clamped; the fill never shrinks
// when a later value is lower, so a stale status read cannot move the bar backwards.
Item {
  id: root

  property real value: 0
  property real shown: 0

  implicitWidth: 240
  implicitHeight: 6
  height: implicitHeight

  onValueChanged: shown = Math.max(shown, Math.min(1, Math.max(0, value)))

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: Theme.hair2
  }
  Rectangle {
    objectName: "progressFill"
    width: parent.width * root.shown
    height: parent.height
    radius: height / 2
    color: Theme.accent
  }
}
