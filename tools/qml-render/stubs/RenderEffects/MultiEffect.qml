import QtQuick

// The software scene graph has no shader effects, so MultiEffect cannot tint. This stand-in shows the source
// untinted, which keeps size and placement honest. Colors from colorizationColor are not reproduced.
Item {
  id: root
  property Item source: null
  property real colorization: 0
  property color colorizationColor: "transparent"
  property real brightness: 0
  property real contrast: 0
  property real saturation: 0
  property real blur: 0
  property bool blurEnabled: false
  property bool shadowEnabled: false

  ShaderEffectSource {
    anchors.fill: parent
    sourceItem: root.source
    live: true
  }
}
