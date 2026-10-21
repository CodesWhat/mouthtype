import QtQuick
import "../design"
import "TransformModel.js" as Model

// The editable result. Added segments get a tint drawn behind the text; the tint is recomputed against the original
// while the user edits (backend spans while the text is untouched). Highlights live in the text's own coordinate
// space, so they scroll with it. Over the highlight cap there are no rectangles at all.
Rectangle {
  id: root

  property var session: Model.empty()
  property real maxHeight: 240
  property bool editable: true
  readonly property alias text: edit.text
  readonly property alias editor: edit
  // Marked ranges for the text shown, and the tint rectangles built from them.
  property var ranges: []
  property var rects: []
  property string settled: ""

  implicitHeight: Math.min(maxHeight, Math.max(44, Math.ceil(edit.contentHeight) + 20))
  height: implicitHeight
  radius: 8
  color: Theme.surface
  border.width: 1
  border.color: edit.activeFocus ? Theme.focus : Theme.hair

  function load() {
    edit.text = session.result
    settled = session.result
  }
  function recompute() {
    ranges = Model.addedRanges(Model.diffFor(session, settled))
    rebuild.restart()
  }

  // A new model result replaces whatever the user typed, even when its text is the same as before.
  readonly property int serial: session.serial
  onSerialChanged: load()
  onSessionChanged: recompute()
  onSettledChanged: recompute()
  Component.onCompleted: load()

  Timer {
    id: settle
    interval: 150
    onTriggered: root.settled = edit.text
  }
  Timer {
    id: rebuild
    interval: 0
    onTriggered: {
      var out = []
      var value = edit.text
      for (var i = 0; i < root.ranges.length; i++) {
        var start = root.ranges[i][0]
        var end = Math.min(root.ranges[i][1], value.length)
        if (start >= end) continue
        var begin = edit.positionToRectangle(start)
        var left = begin.x
        var top = begin.y
        var height = begin.height
        var last = start
        for (var p = start + 1; p <= end; p++) {
          if (p < end && value.charCodeAt(p) >= 0xDC00 && value.charCodeAt(p) <= 0xDFFF) continue
          var here = edit.positionToRectangle(p)
          if (p < end && Math.abs(here.y - top) < 2) { last = p; continue }
          var width = Math.abs(here.y - top) < 2
            ? here.x - left : edit.positionToRectangle(last).x + measure.advanceWidth(value.substring(last, last + (value.charCodeAt(last) >= 0xD800 && value.charCodeAt(last) <= 0xDBFF ? 2 : 1))) - left
          // Right-to-left runs walk the cursor leftwards, so the width comes out negative.
          if (width !== 0) out.push({ x: width < 0 ? left + width : left, y: top, width: Math.abs(width), height: height })
          left = here.x
          top = here.y
          height = here.height
          last = p
        }
      }
      root.rects = out
    }
  }
  FontMetrics { id: measure; font: edit.font }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: 1
    contentWidth: width
    contentHeight: edit.contentHeight + 20
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Repeater {
      model: root.rects
      delegate: Rectangle {
        required property var modelData
        x: 12 + modelData.x
        y: 10 + modelData.y
        width: modelData.width
        height: modelData.height
        radius: 2
        color: Theme.c1
      }
    }
    TextEdit {
      id: edit
      x: 12
      y: 10
      width: flick.width - 24
      readOnly: !root.editable
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      color: Theme.ink
      selectionColor: Theme.sel
      selectedTextColor: Theme.ink
      font: Type.sans(Type.body)
      opacity: root.editable ? 1 : 0.6
      onTextChanged: {
        if (text === root.session.result || text === root.settled) { settle.stop(); root.settled = text }
        else settle.restart()
      }
      onContentHeightChanged: rebuild.restart()
      onWidthChanged: rebuild.restart()
      onCursorRectangleChanged: {
        if (cursorRectangle.y < flick.contentY) flick.contentY = cursorRectangle.y
        else if (cursorRectangle.y + cursorRectangle.height + 20 > flick.contentY + flick.height)
          flick.contentY = cursorRectangle.y + cursorRectangle.height + 20 - flick.height
      }
      Accessible.role: Accessible.EditableText
      Accessible.name: "Result"
    }
  }
  Rectangle {
    visible: flick.contentHeight > flick.height + 1
    x: parent.width - 6
    y: 4 + flick.visibleArea.yPosition * (parent.height - 8)
    width: 3
    height: Math.max(16, flick.visibleArea.heightRatio * (parent.height - 8))
    radius: 2
    color: Theme.hair
  }
}
