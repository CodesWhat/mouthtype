import QtQuick
import QtTest

// The menu parts load without qs.Commons, take a style object, and fall back to the Theme-backed MenuStyle. The harness copies
// the three parts, MenuStyle.qml and design/ next to this file.
TestCase {
  id: tc

  name: "MenuParts"
  when: windowShown
  visible: true
  width: 400
  height: 200

  Component { id: rowComponent; MenuRow { label: "Copy"; detail: "Cmd C"; chevron: true } }
  Component { id: buttonComponent; ControlButton { label: "Save" } }
  Component { id: dividerComponent; MenuDivider {} }
  Component {
    id: scaledStyle
    QtObject {
      property color accent: "#ff0000"
      property color mutedBackground: "#00ff00"
      property color foreground: "#0000ff"
      property var font: ({ family: "Sans", body: 10, bodySmall: 9, title: 14 })
      function space(n) { return n * 2 }
    }
  }

  function test_defaults_load() {
    var row = createTemporaryObject(rowComponent, tc)
    verify(row !== null)
    compare(row.implicitWidth, 320)
    compare(row.implicitHeight, 28)
    var button = createTemporaryObject(buttonComponent, tc)
    verify(button !== null)
    verify(button.implicitWidth > 20)
    var divider = createTemporaryObject(dividerComponent, tc)
    compare(divider.implicitHeight, 9)
  }

  function test_style_object_is_used() {
    var style = createTemporaryObject(scaledStyle, tc)
    var row = createTemporaryObject(rowComponent, tc, { style: style })
    compare(row.implicitWidth, 640)
    compare(row.implicitHeight, 56)
    var button = createTemporaryObject(buttonComponent, tc, { style: style })
    compare(button.color, Qt.color("#ff0000"))
    button.enabled = false
    compare(button.color, Qt.color("#00ff00"))
    var divider = createTemporaryObject(dividerComponent, tc, { style: style })
    compare(divider.implicitHeight, 18)
  }

  function test_clicks() {
    var row = createTemporaryObject(rowComponent, tc)
    var fired = 0
    row.activated.connect(function () { fired++ })
    mouseClick(row)
    compare(fired, 1)
    var button = createTemporaryObject(buttonComponent, tc)
    var clicks = 0
    button.clicked.connect(function () { clicks++ })
    mouseClick(button)
    compare(clicks, 1)
  }
}
