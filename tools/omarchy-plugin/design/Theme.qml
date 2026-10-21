pragma Singleton
import QtQuick
import "Palette.js" as P

// The shared palette. `Theme.dark` follows Omarchy's dark flag when the shell exposes one and falls back to light when it
// does not. Set `Theme.forceDark` to true or false to pin a mode (the render gallery does); leave it null to follow Omarchy.
// Colours come from Palette.js, which mirrors DesignPalette.swift. Never use the accent as a text colour: use accentText.
QtObject {
  id: root

  property var forceDark: null

  // Omarchy's Color singleton lives in qs.Commons, which only exists inside the shell. It is probed at runtime so this file
  // still loads in the render harness and anywhere else without it. The flag name is not documented, so a few are tried.
  property var probe: null
  readonly property bool shellDark: probe ? probe.value === true : false
  readonly property bool dark: forceDark === null || forceDark === undefined ? shellDark : forceDark === true

  Component.onCompleted: {
    try {
      probe = Qt.createQmlObject(
        'import QtQuick\nimport qs.Commons\nQtObject {\n' +
        '  readonly property var value: {\n' +
        '    var names = ["isDark", "dark", "darkMode", "isDarkMode"]\n' +
        '    for (var i = 0; i < names.length; i++) {\n' +
        '      var v = Color[names[i]]\n' +
        '      if (typeof v === "boolean") return v\n' +
        '    }\n' +
        '    return null\n' +
        '  }\n}', root, "ThemeShellProbe.qml")
    } catch (e) {
      probe = null
    }
  }

  function c(name) { return P.get(dark, name) }

  readonly property color bg: c("bg")
  readonly property color surface: c("surface")
  readonly property color ink: c("ink")
  readonly property color ink2: c("ink2")
  readonly property color ink3: c("ink3")
  readonly property color hair: c("hair")
  readonly property color hair2: c("hair2")
  readonly property color accent: c("accent")
  readonly property color accentSoft: c("accentSoft")
  readonly property color onAccent: c("onAccent")
  readonly property color accentText: c("accentText")
  readonly property color focus: c("focus")
  readonly property color orange: c("orange")
  readonly property color success: c("success")
  readonly property color danger: c("danger")
  readonly property color gold: c("gold")
  readonly property color silver: c("silver")
  readonly property color bronze: c("bronze")
  readonly property color personalBest: c("personalBest")
  readonly property color personalBestInk: c("personalBestInk")
  readonly property color sel: c("sel")
  readonly property color c0: c("c0")
  readonly property color c1: c("c1")
  readonly property color c2: c("c2")
  readonly property color c3: c("c3")
  readonly property color c4: c("c4")
  readonly property color track: c("track")
  readonly property color key: c("key")
  readonly property color scrim: c("scrim")
  readonly property color sideBase: c("sideBase")
  readonly property color sideInk: c("sideInk")
  readonly property color sideTop: c("sideTop")
  readonly property color sideBottom: c("sideBottom")
  readonly property color shadow: c("shadow")

  // The chart ramp, one lime hue from light to dark. Marks that are not the highlight use neutralMark or track.
  readonly property var chart: [c0, c1, c2, c3, c4]
  readonly property color neutralMark: Qt.rgba(ink3.r, ink3.g, ink3.b, 0.55)

  // Shared geometry from the Mac components.
  readonly property real cardRadius: 12
  readonly property real controlRadius: 7
  readonly property real navRadius: 8
  readonly property real rowMinHeight: 48
  readonly property real controlHeight: 28
}
