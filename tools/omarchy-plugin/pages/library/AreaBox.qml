import QtQuick
import QtQuick.Controls
import "../../design"

// A multi-line mono text box in the design language: surface fill, hair border, the focus ring when active. It scrolls when
// the text is taller than the box. Ctrl+Return is left to the sheet's shortcut.
Rectangle {
  id: root

  property alias text: area.text
  property alias area: area
  property string hint: ""

  implicitHeight: 112
  radius: Theme.controlRadius
  color: Theme.surface
  border.width: area.activeFocus ? 2 : 1
  border.color: area.activeFocus ? Theme.focus : Theme.hair

  function insertText(snippet) {
    var start = area.selectionStart
    var end = area.selectionEnd
    area.remove(start, end)
    area.insert(start, snippet)
    area.cursorPosition = start + snippet.length
    area.forceActiveFocus()
  }

  function forceFocus() { area.forceActiveFocus() }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: 2
    contentWidth: width
    contentHeight: area.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    TextArea.flickable: TextArea {
      id: area
      width: flick.width
      leftPadding: 8
      rightPadding: 8
      topPadding: 6
      bottomPadding: 6
      wrapMode: TextEdit.Wrap
      color: Theme.ink
      selectionColor: Theme.accent
      selectedTextColor: Theme.onAccent
      font: Type.mono(Type.detail)
      background: null
      persistentSelection: true

      Text {
        visible: area.text === "" && !area.preeditText
        x: area.leftPadding
        y: area.topPadding
        width: area.width - area.leftPadding - area.rightPadding
        text: root.hint
        wrapMode: Text.Wrap
        color: Theme.ink3
        font: area.font
      }
    }

    ScrollBar.vertical: ScrollBar {}
  }
}
