import QtQuick
import RenderHarness

// The popup becomes an in-place Item sized to its content. Grabbed as "panel-popup".
Rectangle {
  property Item anchorItem: null
  property var owner: null
  property var bar: null
  property bool open: false
  property real padding: 0
  property Item focusTarget: null
  property real contentWidth: 0
  property real contentHeight: 0

  function fittedContentWidth(wanted) { return wanted }
  function fittedContentHeight(wanted, limit) { return Math.min(wanted, limit) }

  width: contentWidth
  height: contentHeight
  color: RenderRegistry.backdrop
  Component.onCompleted: RenderRegistry.register("panel-popup", this)
}
