pragma Singleton
import QtQuick

// Stand-in for Omarchy's Style. Sizes are guesses at a 1x desktop.
QtObject {
  function space(value) { return value }
  readonly property QtObject font: QtObject {
    readonly property string family: "DejaVu Sans"
    readonly property int title: 16
    readonly property int body: 14
    readonly property int bodySmall: 12
  }
  readonly property QtObject bar: QtObject {
    readonly property int iconSlot: 28
  }
}
