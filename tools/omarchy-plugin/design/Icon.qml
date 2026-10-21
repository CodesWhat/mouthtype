import QtQuick
import "IconData.js" as Data

// A Phosphor Icons glyph (regular weight, 256x256 grid, MIT) in a flat colour. `name` is the file name in icons/ without .svg, or one of the
// aliases below. The colour is baked into an inline SVG, so it renders the same on the GPU and software backends.
//
//   Icon { name: "house"; size: 18; color: Theme.ink2 }
//
// The glyphs are vector outlines, so any size scales cleanly. Sidebar rows use 18, modal rows 16.
Item {
  id: root

  property string name: ""
  property real size: 24
  property color color: Theme.ink2

  // Names the Mac UI uses that Phosphor spells differently.
  readonly property var aliases: ({
    "flame": "fire", "warning": "warning-diamond", "close": "x", "search": "magnifying-glass",
    "chevron-left": "caret-left", "chevron-right": "caret-right", "chevron-up": "caret-up", "chevron-down": "caret-down"
  })
  readonly property string resolvedName: aliases[name] !== undefined ? aliases[name] : name
  readonly property bool known: Data.paths[resolvedName] !== undefined

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size

  function svg() {
    var d = Data.paths[resolvedName]
    if (d === undefined) return ""
    var r = Math.round(color.r * 255), g = Math.round(color.g * 255), b = Math.round(color.b * 255)
    return '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">' +
           '<path fill="rgb(' + r + ',' + g + ',' + b + ')" fill-opacity="' + color.a.toFixed(3) + '" d="' + d + '"/></svg>'
  }

  Image {
    anchors.fill: parent
    visible: root.known
    source: root.known ? "data:image/svg+xml;utf8," + encodeURIComponent(root.svg()) : ""
    sourceSize: Qt.size(Math.ceil(root.size * Screen.devicePixelRatio), Math.ceil(root.size * Screen.devicePixelRatio))
    fillMode: Image.PreserveAspectFit
    smooth: true
    cache: true
    asynchronous: false
  }

  Accessible.ignored: true
}
