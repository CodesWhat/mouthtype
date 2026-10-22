import QtQuick
import QtTest
import MouthtypePlatform

// AppState against the scripted fake Platform, replaying control.py replies. The harness copies AppState.qml and Fonts.js
// next to this file.
TestCase {
  id: tc

  name: "AppState"
  when: windowShown

  property var shellStub: QtObject {
    property string page: "home"
    property bool pageBusy: false
    property var visited: []
    property var results: []
    property var failures: []
    function navigate(name) { visited = visited.concat([name]); page = name }
    function pageResult(command, result) { results = results.concat([[command, result]]) }
    function pageFailed(message) { failures = failures.concat([message]) }
  }

  Component {
    id: appComponent
    AppState { helper: "control.py"; fallbackFont: "Sans" }
  }

  function init() {
    Platform.reset()
    shellStub.page = "home"
    shellStub.pageBusy = false
    shellStub.visited = []
    shellStub.results = []
    shellStub.failures = []
  }

  function make(replies) {
    Platform.replies = replies
    var app = createTemporaryObject(appComponent, tc)
    app.shell = shellStub
    return app
  }

  readonly property string fullState: JSON.stringify({
    running: true, state: "idle", recent: [{ id: "a" }], has_transcript: true, saved: [{ id: "s" }, { id: "t" }],
    config: { language: "en" }, words_today: 42, sounds: true, autostart: true, shortcut: "toggle", shortcut_keys: "SUPER+M",
    capabilities: { file_transcription: true }, pill: { enabled: false, skin: "hifi", size: 2 },
    versions: { plugin: "1", app: "2" }, file_import: { state: "finished", id: "f1" }
  })

  function test_state_reply_is_absorbed() {
    var app = make({ "control.py state": { out: fullState, code: 0 } })
    tryCompare(app, "serviceRunning", true)
    compare(app.sessionState, "idle")
    compare(app.recent.length, 1)
    compare(app.savedCount, 2)
    compare(app.wordsToday, 42)
    compare(app.soundsEnabled, true)
    compare(app.autostartEnabled, true)
    compare(app.shortcutMode, "toggle")
    compare(app.shortcutKeys, "SUPER+M")
    compare(app.canImportFiles, true)
    compare(app.pillPrefs.skin, "hifi")
    compare(app.versions.app, "2")
    compare(app.importHasResult, true)
    compare(app.glyphState, "idle")
    compare(app.lastState.words_today, 42)
  }

  function test_glyph_follows_service_and_session_state() {
    var app = make({ "control.py state": { out: "{}", code: 0 } })
    compare(app.glyphState, "unavailable")
    app.absorb({ running: true, state: "recording" })
    compare(app.glyphState, "recording1")
    app.lipsFrame = 2
    compare(app.glyphState, "recording2")
    app.absorb({ state: "transcribing" })
    compare(app.lipsFrame, 1)
    compare(app.glyphState, "processing")
  }

  function test_bad_state_json_sets_an_error() {
    var app = make({ "control.py state": { out: "not json", code: 0 } })
    tryCompare(app, "errorText", "Could not read Mouthtype status")
  }

  function test_actions_are_single_flight_and_refresh_afterwards() {
    var app = make({ "control.py state": { out: "{}", code: 0 }, "control.py toggle": { out: "{\"message\":\"ok\"}", code: 0 } })
    tryCompare(app, "stateBusy", false)
    var before = Platform.calls.length
    app.run(["toggle"])
    app.run(["toggle"])
    tryCompare(app, "notice", "ok")
    tryVerify(function() { return Platform.calls.length >= before + 2 })
    var toggles = Platform.calls.filter(function(c) { return c.join(" ") === "control.py toggle" })
    compare(toggles.length, 1)
    compare(Platform.calls[Platform.calls.length - 1].join(" "), "control.py state")
  }

  function test_page_requests_run_in_order_and_reach_the_shell() {
    var app = make({
      "control.py state": { out: "{}", code: 0 },
      "control.py first 1": { out: "{\"n\":1}", code: 0 },
      "control.py second": { out: "{\"n\":2}", code: 0 }
    })
    app.pageRequest("first", [1])
    app.pageRequest("second", [])
    compare(shellStub.pageBusy, true)
    tryVerify(function() { return shellStub.results.length === 2 })
    compare(shellStub.results[0][0], "first")
    compare(shellStub.results[0][1].n, 1)
    compare(shellStub.results[1][0], "second")
    tryCompare(shellStub, "pageBusy", false)
  }

  function test_page_request_with_bad_json_reports_failure() {
    var app = make({ "control.py state": { out: "{}", code: 0 }, "control.py broken": { out: "nope", code: 0 } })
    app.pageRequest("broken", [])
    tryVerify(function() { return shellStub.failures.length === 1 })
    compare(shellStub.failures[0], "Mouthtype page request failed")
  }

  function test_recover_shows_the_transcript_page() {
    var app = make({ "control.py state": { out: "{}", code: 0 }, "control.py recover abc": { out: "{\"text\":\"hello\"}", code: 0 } })
    app.showRecording("abc")
    tryCompare(app, "transcript", "hello")
    compare(app.transcriptId, "abc")
    compare(shellStub.visited[shellStub.visited.length - 1], "transcript")
  }

  function test_file_import_text_loads_for_a_finished_import_on_the_import_page() {
    var app = make({ "control.py state": { out: "{}", code: 0 }, "control.py import-result": { out: "{\"text\":\"words\"}", code: 0 } })
    shellStub.page = "import"
    app.absorb({ file_import: { state: "finished", id: "f9" } })
    tryCompare(app, "importText", "words")
    compare(app.importTextFor, "f9")
    app.absorb({ file_import: { state: "transcribing", id: "f9" } })
    compare(app.importText, "")
    compare(app.importActive, true)
  }

  function test_opening_refreshes_and_closing_goes_home() {
    var app = make({ "control.py state": { out: "{}", code: 0 } })
    tryCompare(app, "stateBusy", false)
    var before = Platform.calls.length
    app.opened = true
    tryVerify(function() { return Platform.calls.length > before })
    app.transcript = "x"
    app.opened = false
    compare(app.transcript, "")
    compare(shellStub.visited[shellStub.visited.length - 1], "home")
  }

  function test_page_in_a_reply_navigates_and_asks_to_open() {
    var app = make({ "control.py state": { out: "{}", code: 0 } })
    var asked = 0
    app.openRequested.connect(function() { asked++ })
    app.absorb({ page: "stats" })
    compare(shellStub.visited[shellStub.visited.length - 1], "stats")
    compare(asked, 1)
  }

  function test_lips_frame_comes_from_the_watched_file_while_recording() {
    Platform.envValues = { XDG_RUNTIME_DIR: "/run/u" }
    Platform.files = { "/run/u/mouthtype/bar-lips": "2" }
    var app = make({ "control.py state": { out: "{}", code: 0 } })
    app.absorb({ running: true, state: "recording" })
    Platform.writeFile("/run/u/mouthtype/bar-lips", "0")
    tryCompare(app, "lipsFrame", 0)
    Platform.writeFile("/run/u/mouthtype/bar-lips", "9")
    wait(50)
    compare(app.lipsFrame, 0)
  }

  function test_clock_and_import_label() {
    var app = make({ "control.py state": { out: "{}", code: 0 } })
    compare(app.clock(75), "1:15")
    compare(app.clock(null), "")
    app.absorb({ file_import: { state: "transcribing", duration_seconds: 5 } })
    compare(app.importLabel(), "Transcribing · 0:05…")
  }
}
