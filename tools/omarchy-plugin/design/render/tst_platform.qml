import QtQuick
import QtTest
import MouthtypePlatform

// qmltestrunner checks for the platform contract, run against the scripted fake (design/render/fake). The Quickshell
// implementation needs a running shell, so its names are checked by test_platform.py and its behaviour by the Omarchy smoke.
TestCase {
  id: tc

  name: "MouthtypePlatform"
  when: windowShown

  function init() { Platform.reset() }

  function test_env() {
    Platform.envValues = { HOME: "/home/x" }
    compare(Platform.env("HOME"), "/home/x")
    compare(Platform.env("NOPE"), "")
  }

  function test_run_reports_output_and_exit_code_once() {
    Platform.replies = { "control.py state": { out: "{\"ok\":true}", code: 0 }, "control.py boom": { out: "x", code: 3 } }
    var got = []
    Platform.run(["control.py", "state"], function(out, code) { got.push([out, code]) })
    Platform.run(["control.py", "boom"], function(out, code) { got.push([out, code]) })
    Platform.run(["control.py", "missing"], function(out, code) { got.push([out, code]) })
    compare(got.length, 0, "callbacks must be asynchronous")
    tryCompare(got, "length", 3)
    compare(got[0][0], "{\"ok\":true}")
    compare(got[0][1], 0)
    compare(got[1][1], 3)
    compare(got[2][1], 127)
    compare(Platform.calls.length, 3)
  }

  function test_read_file() {
    Platform.files = { "/a": "hello" }
    compare(Platform.readFile("/a"), "hello")
    compare(Platform.readFile("/missing"), "")
  }

  function test_watch_fires_on_load_and_on_change_until_destroyed() {
    Platform.files = { "/w": "one" }
    var seen = []
    var handle = Platform.watch("/w", function(text) { seen.push(text) })
    tryCompare(seen, "length", 1)
    compare(seen[0], "one")
    Platform.writeFile("/w", "two")
    tryCompare(seen, "length", 2)
    compare(seen[1], "two")
    handle.destroy()
    Platform.writeFile("/w", "three")
    wait(50)
    compare(seen.length, 2)
  }

  function test_open_url_and_layer_shell_default() {
    Platform.openUrl("https://mouthtype.app")
    compare(Platform.urls[0], "https://mouthtype.app")
    compare(Platform.isLayerShell, false)
    compare(Platform.focusedScreen, null)
  }
}
