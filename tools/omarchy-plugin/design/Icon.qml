import QtQuick
import "IconData.js" as Data

// A Pixelarticons glyph (24x24 grid, MIT) in a flat colour. `name` is the file name in icons/ without .svg, or one of the
// aliases below. The colour is baked into an inline SVG, so it renders the same on the GPU and software backends.
//
//   Icon { name: "home"; size: 24; color: Theme.ink2 }
//
// 24 is the native size: one grid pixel is one pixel. Other sizes scale the grid.
Item {
  id: root

  property string name: ""
  property real size: 24
  property color color: Theme.ink2

  // Names the Mac UI uses that Pixelarticons spells differently.
  readonly property var aliases: ({ "flame": "fire", "warning": "warning-diamond" })
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
    return '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">' +
           '<path fill="rgb(' + r + ',' + g + ',' + b + ')" fill-opacity="' + color.a.toFixed(3) + '" d="' + d + '"/></svg>'
  }

  Image {
    anchors.fill: parent
    visible: root.known
    source: root.known ? "data:image/svg+xml;utf8," + encodeURIComponent(root.svg()) : ""
    sourceSize: Qt.size(Math.ceil(root.size * Screen.devicePixelRatio), Math.ceil(root.size * Screen.devicePixelRatio))
    fillMode: Image.PreserveAspectFit
    smooth: false
    cache: true
    asynchronous: false
  }

  Accessible.ignored: true
}
