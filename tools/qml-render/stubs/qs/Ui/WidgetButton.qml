import QtQuick
import RenderHarness

// Grabbed as "bar-button".
Rectangle {
  property var bar: null
  property bool labelVisible: true
  property bool hasVisualContent: false
  property real fixedWidth: 0
  property string tooltipText: ""
  property bool active: false
  signal pressed(var code)

  implicitWidth: fixedWidth > 0 ? fixedWidth : 28
  implicitHeight: 28
  color: RenderRegistry.backdrop
  Component.onCompleted: RenderRegistry.register("bar-button", this)
}
