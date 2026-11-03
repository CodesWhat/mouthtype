import QtQuick
import QtTest
import "../design"

// qmltestrunner scene: grabs PillSheet in light and dark and runs the mechanical checks: text at least 10 px, no elide, no
// Text wider than its parent, bundled fonts loaded. PNGs go to /tmp/mouthtype-pill-<mode>.png.
TestCase {
  id: tc

  name: "PillSheet"
  when: windowShown
  width: 760
  height: 980

  PillSheet {
    id: sheet
    anchors.fill: parent
  }

  function walk(item, found) {
    if (item.text !== undefined && item.font !== undefined && item.elide !== undefined) found.push(item)
    for (var i = 0; i < item.children.length; i++) walk(item.children[i], found)
    return found
  }

  function test_1_fonts_loaded() {
    tryVerify(function() { return Type.ready }, 3000, "bundled fonts did not load")
  }

  function test_2_text_rules() {
    wait(300)
    var texts = walk(sheet, [])
    verify(texts.length > 20, "found " + texts.length + " texts")
    for (var i = 0; i < texts.length; i++) {
      var t = texts[i]
      if (t.text === "" || !t.visible) continue
      verify(t.font.pixelSize >= 10, "below the floor: '" + t.text + "' " + t.font.pixelSize)
      compare(t.elide, Text.ElideNone, "elide set on '" + t.text + "'")
      if (t.parent && t.parent.width > 0) verify(t.width <= t.parent.width + 0.5, "overflows its parent: '" + t.text + "'")
    }
  }

  property var saved: ({})

  function render(mode) {
    sheet.dark = mode === "dark"
    wait(500)
    saved[mode] = undefined
    sheet.grabToImage(function(result) { saved[mode] = result.saveToFile("/tmp/mouthtype-pill-" + mode + ".png") })
    tryVerify(function() { return saved[mode] !== undefined }, 3000, "grab never finished")
    verify(saved[mode] === true, "could not save " + mode)
  }

  function test_3_render_light() { render("light") }
  function test_4_render_dark() { render("dark") }
}
