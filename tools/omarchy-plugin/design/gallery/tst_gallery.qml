import QtQuick
import QtTest
import ".."

// qmltestrunner scene: grabs the gallery in light and dark, and runs the mechanical checks from the render plan: bundled
// fonts loaded, the 10 px floor (9 only on items tagged axisLabel), no elide, no Text wider than its parent, every icon
// name resolves. PNGs go to /tmp/mouthtype-gallery-<mode>.png.
TestCase {
  id: tc

  name: "DesignGallery"
  when: windowShown
  width: 760
  height: 1000

  DesignGallery {
    id: gallery
    anchors.fill: parent
  }

  function walk(item, found) {
    if (item.text !== undefined && item.font !== undefined && item.elide !== undefined) found.push(item)
    for (var i = 0; i < item.children.length; i++) walk(item.children[i], found)
    return found
  }

  function walkIcons(item, found) {
    if (item.resolvedName !== undefined && item.known !== undefined) found.push(item)
    for (var i = 0; i < item.children.length; i++) walkIcons(item.children[i], found)
    return found
  }

  function test_1_fonts_loaded() {
    tryVerify(function() { return Type.ready }, 3000, "bundled fonts did not load")
    verify(Type.serifFamily.indexOf("Instrument Serif") === 0, "serif family " + Type.serifFamily)
    verify(Type.sansFamily.indexOf("Instrument Sans") === 0, "sans family " + Type.sansFamily)
    verify(Type.monoFamily.indexOf("JetBrains Mono") === 0, "mono family " + Type.monoFamily)
  }

  function test_2_text_rules() {
    var texts = walk(gallery, [])
    verify(texts.length > 20, "found " + texts.length + " texts")
    for (var i = 0; i < texts.length; i++) {
      var t = texts[i]
      var axis = t.axisLabel === true
      verify(t.font.pixelSize >= (axis ? 9 : 10), "below the floor: '" + t.text + "' " + t.font.pixelSize)
      compare(t.elide, Text.ElideNone, "elide set on '" + t.text + "'")
      if (t.parent && t.parent.width > 0) verify(t.width <= t.parent.width + 0.5, "overflows its parent: '" + t.text + "'")
    }
  }

  function test_3_icons_resolve() {
    var icons = walkIcons(gallery, [])
    verify(icons.length > 20, "found " + icons.length + " icons")
    for (var i = 0; i < icons.length; i++) verify(icons[i].known, "unknown icon '" + icons[i].name + "'")
  }

  property var saved: ({})

  function render(mode) {
    gallery.dark = mode === "dark"
    wait(400)
    saved[mode] = undefined
    gallery.grabToImage(function(result) { saved[mode] = result.saveToFile("/tmp/mouthtype-gallery-" + mode + ".png") })
    tryVerify(function() { return saved[mode] !== undefined }, 3000, "grab never finished")
    verify(saved[mode] === true, "could not save " + mode)
  }

  function test_4_render_light() { render("light") }
  function test_5_render_dark() { render("dark") }
}
