import QtQuick
import QtQuick.Effects

// A fixed-cell bitmap face from the Hi-Fi skin: one row of glyph cells in a white-on-transparent atlas,
// drawn one cell per character at whole art pixels, uppercased by lookup, tinted, centred in its slot or
// scrolled once when wider than the slot.
Item {
  id: root
  property var slot: null
  property var fontSpec: null
  property string atlas: ""
  property string text: ""
  property color tint: "#ffb02e"
  property int artScale: 1
  property bool marquee: false

  readonly property int cellWidth: fontSpec ? fontSpec.cellWidth : 0
  readonly property int cellHeight: fontSpec ? fontSpec.cellHeight : 0
  readonly property int gap: fontSpec ? fontSpec.gap : 1
  readonly property string chars: fontSpec ? fontSpec.chars : ""
  readonly property int slotWidth: slot ? slot.maxWidth : 0

  function glyphIndex(character) {
    var index = chars.indexOf(character)
    if (index !== -1) return index
    index = chars.indexOf(character.toUpperCase())
    return index === -1 ? 0 : index
  }
  function advance(index) {
    var character = chars.charAt(index)
    return fontSpec && fontSpec.advances && fontSpec.advances[character] !== undefined ? fontSpec.advances[character] : cellWidth
  }
  readonly property var placements: {
    var out = [], x = 0
    for (var i = 0; i < text.length; i++) {
      var index = glyphIndex(text.charAt(i))
      out.push({ index: index, x: x })
      x += advance(index) + gap
    }
    return out
  }
  readonly property int textWidth: placements.length ? placements[placements.length - 1].x + advance(placements[placements.length - 1].index) : 0
  readonly property int distance: Math.max(0, textWidth - slotWidth)
  readonly property int restingOffset: textWidth <= slotWidth ? Math.floor((slotWidth - textWidth) / 2) : 0
  property int scrollOffset: 0

  x: (slot ? slot.x : 0) * artScale
  y: (slot ? slot.y : 0) * artScale
  width: slotWidth * artScale
  height: cellHeight * artScale
  clip: true

  onTextChanged: { scrollOffset = 0; scrollTimer.restart() }
  Timer {
    id: scrollTimer
    interval: 600
    repeat: false
    onTriggered: if (root.marquee && root.distance > 0) scroller.restart()
  }
  NumberAnimation {
    id: scroller
    target: root
    property: "scrollOffset"
    from: 0
    to: -root.distance
    duration: Math.max(1, root.distance / 30 * 1000)
  }

  Item {
    id: glyphs
    x: (root.restingOffset + root.scrollOffset) * root.artScale
    width: root.textWidth * root.artScale
    height: parent.height
    layer.enabled: true
    layer.effect: MultiEffect { colorization: 1.0; colorizationColor: root.tint }
    Repeater {
      model: root.placements.length
      Image {
        required property int index
        readonly property var place: root.placements[index]
        x: place.x * root.artScale
        width: root.cellWidth * root.artScale
        height: root.cellHeight * root.artScale
        source: root.atlas
        sourceClipRect: Qt.rect(place.index * root.cellWidth, 0, root.cellWidth, root.cellHeight)
        smooth: false
        fillMode: Image.Stretch
      }
    }
  }
}
