import QtQuick
import "../../design"

// A mono 10 readout line, tracked .8, the third ink. `value` is drawn in the first ink ahead of the label when set.
Text {
  property string value: ""
  property string label: ""

  textFormat: Text.StyledText
  wrapMode: Text.Wrap
  color: Theme.ink3
  font.family: Type.monoFamily !== "" ? Type.monoFamily : "monospace"
  font.pixelSize: Type.eyebrowSize
  font.weight: Font.Medium
  font.letterSpacing: 0.8
  font.capitalization: Font.AllUppercase
  text: value !== "" ? "<font color='" + Theme.ink + "'>" + value + "</font> <font color='" + Theme.ink2 + "'>" + label + "</font>" : label
}
