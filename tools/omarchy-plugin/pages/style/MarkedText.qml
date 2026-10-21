import QtQuick
import "../../design"
import "StyleLogic.js" as Logic

// One sample line with the characters a tone added drawn on a tint. `spoken` is the dictation as the speech engine hears it
// and `styled` what the tone makes of it, both from the backend's style-state samples. `boxColor` is what the line sits on, so the tint is
// composed over it into one opaque colour (rich text takes a plain CSS colour, not an alpha one).
Text {
  id: root

  property string spoken: ""
  property string styled: ""
  property color boxColor: Theme.bg

  readonly property color tint: Qt.tint(boxColor, Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.16))
  readonly property var runs: Logic.segments(spoken, styled)
  // [{ start, end }] of the highlighted runs, in character positions of `styled`.
  readonly property var markRanges: Logic.ranges(runs)
  // The drawn width of each highlighted run, summed per character from the laid-out text. A run that wrapped counts only the
  // characters that stayed on their own line. The scenes assert every entry is above zero.
  readonly property var markWidths: {
    var layout = probe.contentWidth + probe.contentHeight + probe.width
    var out = []
    // The probe takes the new text a moment after this binding first sees new runs; wait for it rather than ask past its end.
    var ready = probe.length >= styled.length
    for (var i = 0; i < markRanges.length; i++) {
      var w = 0
      if (!ready) { out.push(0); continue }
      for (var p = markRanges[i].start; p < markRanges[i].end; p++) {
        var a = probe.positionToRectangle(p)
        var b = probe.positionToRectangle(p + 1)
        if (Math.abs(a.y - b.y) < 1 && b.x > a.x) w += b.x - a.x
      }
      out.push(w)
    }
    return out
  }

  textFormat: Text.RichText
  wrapMode: Text.Wrap
  color: Theme.ink2
  font: Type.sans(Type.detail)
  lineHeight: 1.15
  text: Logic.markup(runs, tint.toString(), Theme.ink.toString())

  // Text cannot report where a character landed; a TextEdit laid out the same way can. It is never shown.
  TextEdit {
    id: probe
    visible: false
    readOnly: true
    width: root.width
    textFormat: TextEdit.RichText
    wrapMode: TextEdit.Wrap
    font: root.font
    text: root.text
  }

  Accessible.role: Accessible.StaticText
  Accessible.name: styled
}
