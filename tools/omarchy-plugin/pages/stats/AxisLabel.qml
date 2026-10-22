import QtQuick
import "../../design"

// Mono 9 chart axis label, the one place under the 10 px floor. The tag lets the render tests assert the exception only here.
Text {
  property bool axisLabel: true
  color: Theme.ink3
  font.family: Type.monoFamily !== "" ? Type.monoFamily : "monospace"
  font.pixelSize: Type.axisSize
  font.weight: Font.Medium
  font.letterSpacing: 0.5
}
