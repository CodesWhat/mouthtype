import QtQuick
import RenderHarness

// A layer-shell window becomes a plain Item parked in the harness host. The first one is grabbed as "pill-window".
// Children declared inside PanelWindow land in the surface, so anchors.fill: parent behaves as it does in a window.
QtObject {
  id: root
  property var screen: null
  property bool visible: true
  property color color: "transparent"
  property int implicitWidth: 0
  property int implicitHeight: 0
  property var mask: null
  property var exclusionMode: null
  component Anchors: QtObject {
    property bool top: false
    property bool bottom: false
    property bool left: false
    property bool right: false
  }
  component Margins: QtObject {
    property real top: 0
    property real bottom: 0
    property real left: 0
    property real right: 0
  }
  readonly property Anchors anchors: Anchors {}
  readonly property Margins margins: Margins {}

  default property alias content: surface.data
  readonly property Item surface: Rectangle {
    id: surface
    parent: RenderRegistry.host
    width: root.implicitWidth
    height: root.implicitHeight
    visible: root.visible
    color: RenderRegistry.backdrop
  }

  // The first window created is "pill-window", which is the Service's pill. Every window is also "window-N" in creation order.
  Component.onCompleted: {
    var count = Object.keys(RenderRegistry.surfaces).filter(function(key) { return key.indexOf("window-") === 0 }).length + 1
    RenderRegistry.register("window-" + count, surface)
    if (RenderRegistry.surfaces["pill-window"] === undefined) RenderRegistry.register("pill-window", surface)
  }
}
