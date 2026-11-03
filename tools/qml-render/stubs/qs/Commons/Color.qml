pragma Singleton
import QtQuick
import RenderHarness

// Stand-in for Omarchy's palette. The values are plausible, not Omarchy's; they only keep the components legible.
QtObject {
  readonly property bool dark: RenderRegistry.dark
  readonly property color foreground: dark ? "#EDEDED" : "#1D1D1F"
  readonly property color urgent: dark ? "#F19A4B" : "#C0392B"
  readonly property color accent: dark ? "#A6CD52" : "#76A11A"
  readonly property QtObject popups: QtObject {
    readonly property color background: dark ? "#2A2A2C" : "#FFFFFF"
  }
}
