pragma Singleton
import QtQuick
import RenderHarness

QtObject {
  function env(name) { return name === "HOME" ? RenderRegistry.home : "" }
  readonly property var screens: [{ name: "HEADLESS-1", devicePixelRatio: 1 }]
}
