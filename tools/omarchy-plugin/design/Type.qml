pragma Singleton
import QtQuick

// The redesign type scale, mirroring DesignTypography.swift. Instrument Serif for headlines and display words, Instrument
// Sans for everything else, JetBrains Mono for eyebrows and readouts. Sizes are in pixels. Nothing goes below 10; 9 is for
// chart axis labels only (Type.axis). Each helper falls back to the system serif, sans or monospace family until the
// bundled font has loaded, so text never disappears.
QtObject {
  id: root

  readonly property real headline: 28
  readonly property real display: 22
  readonly property real body: 13
  readonly property real detail: 12
  readonly property real caption: 11.5
  readonly property real eyebrowSize: 10
  readonly property real floor: 10
  readonly property real axisSize: 9
  // .12em at 10 px.
  readonly property real eyebrowTracking: 1.2

  readonly property FontLoader serifLoader: FontLoader { source: Qt.resolvedUrl("fonts/InstrumentSerif-Regular.ttf") }
  readonly property FontLoader sansRegularLoader: FontLoader { source: Qt.resolvedUrl("fonts/InstrumentSans-Regular.ttf") }
  readonly property FontLoader sansMediumLoader: FontLoader { source: Qt.resolvedUrl("fonts/InstrumentSans-Medium.ttf") }
  readonly property FontLoader sansSemiBoldLoader: FontLoader { source: Qt.resolvedUrl("fonts/InstrumentSans-SemiBold.ttf") }
  readonly property FontLoader monoLoader: FontLoader { source: Qt.resolvedUrl("fonts/JetBrainsMono-Medium.ttf") }

  // Family names once loaded, "" before. The static weights share one family name; weight picks the face.
  readonly property string serifFamily: serifLoader.status === FontLoader.Ready ? serifLoader.name : ""
  readonly property string sansFamily: sansRegularLoader.status === FontLoader.Ready ? sansRegularLoader.name : ""
  readonly property string monoFamily: monoLoader.status === FontLoader.Ready ? monoLoader.name : ""
  readonly property bool ready: serifFamily !== "" && sansFamily !== "" && monoFamily !== ""

  function px(size) { return Math.max(size, floor) }

  function serif(size) {
    return Qt.font({ family: serifFamily !== "" ? serifFamily : "serif", pixelSize: px(size), weight: Font.Normal })
  }

  // weight: "regular" (default), "medium" or "semibold".
  function sans(size, weight) {
    var w = weight === "semibold" ? Font.DemiBold : weight === "medium" ? Font.Medium : Font.Normal
    return Qt.font({ family: sansFamily !== "" ? sansFamily : "sans-serif", pixelSize: px(size), weight: w })
  }

  function mono(size) {
    return Qt.font({ family: monoFamily !== "" ? monoFamily : "monospace", pixelSize: px(size), weight: Font.Medium })
  }

  // Mono 10 uppercase with .12em tracking. Colour it Theme.ink3 yourself.
  readonly property font eyebrow: Qt.font({
    family: monoFamily !== "" ? monoFamily : "monospace", pixelSize: eyebrowSize, weight: Font.Medium,
    letterSpacing: eyebrowTracking, capitalization: Font.AllUppercase
  })

  // The only 9 px text in the product. Tag any Text that uses it with `property bool axisLabel: true` so the harness
  // knows the exception is deliberate.
  readonly property font axis: Qt.font({ family: sansFamily !== "" ? sansFamily : "sans-serif", pixelSize: axisSize, weight: Font.Normal })
}
