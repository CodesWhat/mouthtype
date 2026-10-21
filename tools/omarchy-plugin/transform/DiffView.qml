import QtQuick
import "../design"
import "TransformModel.js" as Model

// The original text with the segments the transform removed struck through. Selectable, read only, scrolls past
// maxHeight. `segments` is the backend's diff.original list of { text, kind }.
Item {
  id: root

  property var segments: []
  property real maxHeight: 120
  readonly property string html: Model.originalHtml(root.segments, String(Theme.ink3))

  implicitHeight: Math.min(maxHeight, Math.max(22, Math.ceil(edit.contentHeight) + 8))
  height: implicitHeight

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: edit.contentHeight + 8
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    TextEdit {
      id: edit
      x: 0
      y: 2
      width: flick.width - 12
      readOnly: true
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.RichText
      text: root.html
      color: Theme.ink2
      selectionColor: Theme.sel
      selectedTextColor: Theme.ink
      font: Type.sans(12.5)
    }
  }
  Rectangle {
    visible: flick.contentHeight > flick.height + 1
    x: parent.width - 4
    y: flick.visibleArea.yPosition * parent.height
    width: 3
    height: Math.max(16, flick.visibleArea.heightRatio * parent.height)
    radius: 2
    color: Theme.hair
  }
}
