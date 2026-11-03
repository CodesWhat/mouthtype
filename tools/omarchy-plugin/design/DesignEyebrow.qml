import QtQuick

// Mono 10 uppercase label, .12em tracking, the third ink. Pass the text as written; the uppercase is applied here.
Text {
  property bool axisLabel: false
  leftPadding: 4
  wrapMode: Text.Wrap
  color: Theme.ink3
  font: Type.eyebrow
  Accessible.role: Accessible.Heading
  Accessible.name: text
}
