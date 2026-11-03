import QtQuick
import QtTest
import "../design"
import "../pages"
import "../pages/stats/StatsFormat.js" as F
import "StatsFixtures.js" as Fixtures

// qmltestrunner scene for slice V4. Loads StatsPage with real-shaped `stats` JSON (generated from tools/linux-desktop/stats.py by
// gen_stats_fixtures.py) for an empty, one-take, sparse, dense and audio-only history, in light and dark. Runs the mechanical
// text checks (the 9 px exception only on tagged axis labels), the lime restraint, the page contract, and the helper maths.
// PNGs go to /tmp/mouthtype-shell/stats-<scene>-<mode>.png.
TestCase {
  id: tc

  name: "StatsPage"
  when: windowShown
  visible: true
  width: 700
  height: 1500

  property bool dark: false
  Binding { target: Theme; property: "forceDark"; value: tc.dark }

  Rectangle {
    id: frame
    width: 700
    height: page.implicitHeight + 48
    color: Theme.bg

    StatsPage {
      id: page
      x: 32
      y: 24
      width: 636
    }
  }

  SignalSpy { id: requests; target: page; signalName: "request" }

  function walk(item, found) {
    found.push(item)
    for (var i = 0; i < item.children.length; i++) walk(item.children[i], found)
    return found
  }

  function everything() { return walk(page, []) }

  function texts() {
    var out = []
    var all = everything()
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      if (t.text !== undefined && t.font !== undefined && t.elide !== undefined && t.visible && t.width > 0) out.push(t)
    }
    return out
  }

  function findText(fragment) {
    var all = texts()
    for (var i = 0; i < all.length; i++) if (String(all[i].text).indexOf(fragment) >= 0) return all[i]
    return null
  }

  // First visible item that has every named property. (The page holds two Tape items; only one is ever shown.)
  function findWith(names) {
    var all = everything()
    for (var i = 0; i < all.length; i++) {
      var ok = all[i].visible
      for (var j = 0; j < names.length; j++) if (all[i][names[j]] === undefined) { ok = false; break }
      if (ok) return all[i]
    }
    return null
  }

  function show(scene) {
    page.nowSeconds = Fixtures.nowSeconds
    var results = {}
    if (scene !== "loading") results.stats = Fixtures.scenes[scene]
    page.backend = { state: {}, results: results, busy: false, error: "", dark: tc.dark }
    wait(150)
  }

  function checkText(label) {
    var all = texts()
    verify(all.length >= 3, label + ": found " + all.length + " texts")
    var axis = 0
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      if (t.text === "") continue
      if (t.axisLabel === true) {
        compare(t.font.pixelSize, 9, label + ": axis label size '" + t.text + "'")
        axis++
      } else {
        verify(t.font.pixelSize >= 10, label + ": below the floor: '" + t.text + "' " + t.font.pixelSize)
      }
      compare(t.elide, Text.ElideNone, label + ": elide set on '" + t.text + "'")
      if (t.parent && t.parent.width > 0) verify(t.width <= t.parent.width + 0.5, label + ": overflows its parent: '" + t.text + "'")
      verify(!Qt.colorEqual(t.color, Theme.accent), label + ": lime text '" + t.text + "'")
    }
    return axis
  }

  readonly property var scenes: ["loading", "empty", "one_take", "sparse", "dense", "audio_only"]

  function test_render_data() {
    var rows = []
    for (var i = 0; i < scenes.length; i++) {
      rows.push({ tag: scenes[i] + " light", scene: scenes[i], dark: false })
      rows.push({ tag: scenes[i] + " dark", scene: scenes[i], dark: true })
    }
    return rows
  }

  property var saved: ({})

  function test_render(data) {
    tc.dark = data.dark
    show(data.scene)
    var axis = checkText(data.tag)
    if (data.scene === "dense" || data.scene === "sparse") verify(axis >= 6, data.tag + ": expected axis labels, got " + axis)
    if (data.scene === "loading" || data.scene === "empty") compare(axis, 0)
    var key = "stats-" + data.scene + "-" + (data.dark ? "dark" : "light")
    saved[key] = undefined
    frame.grabToImage(function(result) { saved[key] = result.saveToFile("/tmp/mouthtype-shell/" + key + ".png") })
    tryVerify(function() { return saved[key] !== undefined }, 3000, "grab never finished: " + key)
    verify(saved[key] === true, "could not save " + key)
  }

  function test_states() {
    tc.dark = false
    show("loading")
    verify(findText("Reading your history.") !== null)
    show("empty")
    verify(findText("No stats yet. Dictate something") !== null)
    verify(findText("History is limited") === null, "the note belongs with real numbers")
    page.backend = { state: {}, results: {}, busy: false, error: "Mouthtype could not read the history.", dark: false }
    wait(50)
    verify(findText("Mouthtype could not read the history.") !== null)
    show("dense")
    verify(findText("No stats yet") === null)
    verify(findText("Words, all time") !== null)
    verify(findText("Today's tape") !== null)
    verify(findText("Speaking speed") !== null)
    verify(findText("High scores") !== null)
  }

  function test_audio_only_shows_the_tape_alone() {
    tc.dark = false
    show("audio_only")
    verify(findText("Today's tape") !== null)
    verify(findText("Words, all time") === null)
    verify(findText("Speaking speed") === null)
    var tape = findWith(["takes", "slots", "range"])
    verify(tape !== null)
    compare(tape.takes.length, 2)
    verify(findText("History is limited") !== null)
  }

  function test_page_contract() {
    tc.dark = false
    page.active = false
    requests.clear()
    page.active = true
    compare(requests.count, 1)
    compare(requests.signalArguments[0][0], "stats")
    compare(requests.signalArguments[0][1].length, 0)
    page.active = false
    compare(requests.count, 1)
  }

  function test_shown_page_keeps_refreshing() {
    tc.dark = false
    page.active = false
    page.refreshInterval = 50
    requests.clear()
    page.backend = { state: {}, results: {}, busy: false, error: "", dark: false }
    page.active = true
    compare(requests.count, 1)
    tryVerify(function() { return requests.count >= 2 }, 1000, "no refresh while the page stayed open")
    var seen = requests.count
    page.backend = { state: {}, results: {}, busy: true, error: "", dark: false }
    wait(200)
    compare(requests.count, seen, "no new request while one is running")
    page.active = false
    page.refreshInterval = 60000
  }

  function test_history_limited_note() {
    tc.dark = false
    show("dense")
    var note = findText("History is limited to saved takes")
    verify(note !== null)
    verify(note.font.pixelSize >= 10)
    var copy = JSON.parse(JSON.stringify(Fixtures.scenes.dense))
    copy.history_limited = false
    page.backend = { state: {}, results: { stats: copy }, busy: false, error: "", dark: false }
    wait(50)
    verify(findText("History is limited") === null)
  }

  function test_hero() {
    tc.dark = false
    show("dense")
    var hero = findWith(["savedMax", "countText"])
    verify(hero !== null)
    var scene = Fixtures.scenes.dense
    compare(hero.countText, F.number(scene.words.all_time))
    compare(hero.tip, "Since " + F.shortDay(scene.first_day))
    verify(findText("Since") === null, "the start date is a tooltip, not a subline")
    var digits = 0
    var all = texts()
    for (var i = 0; i < all.length; i++) {
      if (all[i].font.pixelSize === 30 && /^[0-9]$/.test(all[i].text)) digits++
    }
    compare(digits, String(scene.words.all_time).length)
    verify(findText("TODAY") !== null || findText("Today") !== null)
    verify(findText("This week") !== null)
    verify(findText("Takes") !== null)
    verify(findText("you didn't have to type.") !== null)
    verify(findText("talking") !== null)
    show("empty")
    verify(findWith(["savedMax", "countText"]) === null || !findWith(["savedMax", "countText"]).visible)
  }

  function test_speed_meter() {
    tc.dark = false
    show("dense")
    var meter = findWith(["averageSegment", "peakSegment", "typistSegment"])
    verify(meter !== null)
    compare(meter.segments, 25)
    compare(meter.maxWpm, 250)
    compare(meter.typistSegment, 3)
    compare(meter.averageSegment, 13)
    compare(meter.peakSegment, 18)
    for (var i = 0; i < 25; i++) {
      var want = i === 18 ? Theme.ink : (i === 13 ? Theme.accent : (i < 13 ? Theme.neutralMark : Theme.track))
      verify(Qt.colorEqual(meter.fill(i), want), "segment " + i)
    }
    compare(meter.caption, "3.4× a typist.")
    verify(findText("3.4× a typist.") !== null)
    var copy = JSON.parse(JSON.stringify(Fixtures.scenes.dense))
    copy.speed.average_wpm = null
    copy.speed.peak_wpm = null
    page.backend = { state: {}, results: { stats: copy }, busy: false, error: "", dark: false }
    wait(50)
    verify(findText("None") !== null)
    compare(meter.caption, "")
    compare(meter.averageSegment, -1)
    verify(Qt.colorEqual(meter.fill(0), Theme.track), "nothing is lit without an average")
  }

  function test_streak_dots() {
    tc.dark = false
    show("dense")
    var streak = findWith(["todayEmpty", "dotColor", "lit"])
    verify(streak !== null)
    compare(streak.count, 30)
    verify(!streak.todayEmpty)
    var copy = JSON.parse(JSON.stringify(Fixtures.scenes.dense))
    copy.daily[29].words = 0
    copy.streak_lit[29] = false
    page.backend = { state: {}, results: { stats: copy }, busy: false, error: "", dark: false }
    wait(50)
    verify(streak.todayEmpty)
    var outlined = 0
    var all = walk(streak, [])
    for (var i = 0; i < all.length; i++) {
      if (all[i].border !== undefined && all[i].radius > 0 && all[i].width === all[i].height && all[i].border.width === 1.5) outlined++
    }
    compare(outlined, 1)
    verify(findText("TODAY") === null, "no caption under the dots")
  }

  function test_hour_chart() {
    tc.dark = false
    show("dense")
    var chart = findWith(["headline", "windowDays", "minChart"])
    verify(chart !== null)
    var scene = Fixtures.scenes.dense
    compare(chart.headline, "A " + F.hourName(scene.peak_hour) + " talker.")
    var headline = findText(chart.headline)
    compare(headline.font.pixelSize, 30)
    verify(chart.detail.indexOf("% of your words.") > 0)
    show("empty")
    compare(chart.headline, "No pattern yet.")
    compare(chart.detail, "")
  }

  function test_high_scores() {
    tc.dark = false
    show("dense")
    var scores = findWith(["rows", "today"])
    verify(scores !== null)
    compare(scores.rows.length, 4)
    compare(scores.rows[0].title, "Fastest speaking")
    verify(Qt.colorEqual(scores.rows[0].medal, Theme.gold))
    verify(Qt.colorEqual(scores.rows[1].medal, Theme.silver))
    verify(Qt.colorEqual(scores.rows[2].medal, Theme.bronze))
    verify(findText("WPM") !== null)
    verify(findText("DAYS") !== null)
    show("sparse")
    verify(findText("Personal best") !== null, "a record set today carries the chip")
    show("empty")
    var none = 0
    var all = texts()
    for (var i = 0; i < all.length; i++) if (all[i].text === "None yet") none++
    compare(none, 0, "the empty state shows no score rows")
    var copy = JSON.parse(JSON.stringify(Fixtures.scenes.dense))
    copy.high_scores = { fastest: null, biggest_day: null, longest_streak: null, longest_take: null }
    page.backend = { state: {}, results: { stats: copy }, busy: false, error: "", dark: false }
    wait(50)
    all = texts()
    none = 0
    for (i = 0; i < all.length; i++) if (all[i].text === "None yet") none++
    compare(none, 4)
  }

  function test_tape() {
    tc.dark = false
    show("dense")
    var tape = findWith(["takes", "slots", "range", "biggest"])
    verify(tape !== null)
    verify(tape.range.end - tape.range.start >= 3)
    verify(tape.slots.length < tape.takes.length, "close takes merge")
    var cap = -1
    for (var i = 0; i < tape.slots.length; i++) if (tape.slots[i].hollow > 0 && tape.slots[i].hollow < tape.slots[i].count) cap = i
    verify(cap >= 0, "a merged slot with an audio-only take gets the cap")
    for (i = 1; i < tape.slots.length; i++) verify(tape.slots[i].x - tape.slots[i - 1].x >= 6 - 0.001, "needles keep 6 px apart")
    var thin = 0
    var all = everything()
    for (i = 0; i < all.length; i++) if (all[i].width === 2.5 && all[i].radius === 1.25) thin++
    verify(thin > 0, "needles are 2.5 wide")
    verify(findText("NOW") !== null)
    verify(findText("NOON") !== null || tape.range.start > 12 || tape.range.end <= 12)

    var area = null
    for (i = 0; i < all.length; i++) if (all[i].visible && all[i].hoverEnabled === true && all[i].acceptedButtons !== undefined) area = all[i]
    verify(area !== null)
    var target = tape.slots[cap]
    mouseMove(area, 1, 1)
    wait(50)
    mouseMove(area, target.x, 20)
    wait(50)
    tryCompare(tape, "hovered", cap, 1000)
    verify(findText("4 takes") !== null || findText(" takes · ") !== null, "merged hover shows the summary")
    var callout = findText(F.slotSummary(target))
    verify(callout !== null, "callout: " + F.slotSummary(target))
    mouseMove(area, area.width / 2, 20)
    mouseMove(area, 1, 1)
    tryCompare(tape, "hovered", -1, 1000)

    show("one_take")
    compare(tape.slots.length, 1)
    compare(tape.biggest, 0)
  }

  function test_lime_only_on_peaks_and_markers() {
    tc.dark = false
    show("empty")
    var limes = 0
    var all = everything()
    for (var i = 0; i < all.length; i++) {
      var item = all[i]
      if (item.visible && item.color !== undefined && item.width > 0 && Qt.colorEqual(item.color, Theme.accent)) limes++
    }
    compare(limes, 0, "nothing lime in the empty state")
    show("dense")
    // The counter, the streak dots and High scores never carry lime.
    var cards = [findWith(["countText"]), findWith(["todayEmpty"]), findWith(["rows", "today"])]
    for (var c = 0; c < cards.length; c++) {
      var inside = walk(cards[c], [])
      for (i = 0; i < inside.length; i++) {
        if (inside[i].visible && inside[i].color !== undefined && inside[i].width > 0) verify(!Qt.colorEqual(inside[i].color, Theme.accent), "lime in card " + c)
        if (inside[i].visible && inside[i].border !== undefined && inside[i].border.width > 0) verify(!Qt.colorEqual(inside[i].border.color, Theme.accent), "lime border in card " + c)
      }
    }
  }

  // ---- helper maths ----

  function test_format_helpers() {
    compare(F.number(1234567), "1,234,567")
    compare(F.number(0), "0")
    compare(F.clock(14 * 3600 + 35 * 60), "2:35 PM")
    compare(F.clock(0), "12:00 AM")
    compare(F.hourName(0), "12 AM")
    compare(F.hourName(13), "1 PM")
    compare(F.savedHeadline(0), "Nothing saved yet.")
    compare(F.savedHeadline(1), "1 minute you didn't have to type.")
    compare(F.savedHeadline(45), "45 minutes you didn't have to type.")
    compare(F.savedHeadline(5280), "88 hours you didn't have to type.")
    compare(F.talkingMinutes(130), "2 h 10 min")
    compare(F.talkingMinutes(12), "12 min")
    compare(F.speaking(0), "")
    compare(F.speaking(768000), "12 min 48 s")
    compare(F.talkingMs(0), "0 s")
    compare(F.shortDay("2026-10-03"), "Oct 3")
    compare(F.date("2026-10-03"), "Oct 3, 2026")
    compare(F.date("bad"), "bad")
    compare(F.recordDate("2026-10-03", "2026-10-20"), "Oct 3")
    compare(F.recordDate("2025-10-03", "2026-10-20"), "Oct 3, 2025")
    compare(F.meterSegment(40, 25, 250), 3)
    compare(F.meterSegment(10, 25, 250), 0)
    compare(F.meterSegment(10.1, 25, 250), 1)
    compare(F.meterSegment(999, 25, 250), 24)
    compare(F.meterSegment(null, 25, 250), -1)
    compare(F.meterSegment(0, 25, 250), -1)
    compare(F.typistRatio(136.62, 40), "3.4× a typist.")
    compare(F.typistRatio(80, 40), "2× a typist.")
    compare(F.typistRatio(50, 40), "")
    compare(F.typistRatio(null, 40), "")
  }

  function test_tape_maths() {
    var one = [{ seconds_into_day: 14 * 3600 + 5 * 60, words: 10, audio_only: false }]
    var range = F.tapeRange(one, 15 * 3600 + 20 * 60)
    compare(range.start, 13)
    compare(range.end, 16)
    var empty = F.tapeRange([], 0)
    compare(empty.end - empty.start, 3)
    var late = F.tapeRange([], 23 * 3600 + 50 * 60)
    compare(late.end, 24)
    compare(late.end - late.start, 3)
    var wide = F.tapeRange([{ seconds_into_day: 6 * 3600, words: 1, audio_only: false }], 20 * 3600)
    verify(wide.end - wide.start >= 14)
    verify(wide.ticks.length < wide.end - wide.start, "wide spans label every few hours")

    var takes = [{ seconds_into_day: 50000, words: 30, audio_only: false },
                 { seconds_into_day: 50004, words: 12, audio_only: true },
                 { seconds_into_day: 51500, words: 80, audio_only: false }]
    var slots = F.mergeSlots(takes, range, 600)
    compare(slots.length, 2)
    compare(slots[0].count, 2)
    compare(slots[0].words, 42)
    compare(slots[0].hollow, 1)
    compare(slots[0].take, null)
    compare(slots[1].take.words, 80)
    compare(F.slotSummary(slots[0]), "2 takes \u00b7 42 words \u00b7 " + F.slotTimeLabel(slots[0]) + " \u00b7 1 audio only")
    compare(F.slotTimeLabel({ firstSeconds: 14 * 3600 + 50 * 60, lastSeconds: 14 * 3600 + 58 * 60 }), "2:50 to 2:58 PM")
    compare(F.slotTimeLabel({ firstSeconds: 11 * 3600 + 50 * 60, lastSeconds: 12 * 3600 + 5 * 60 }), "11:50 AM to 12:05 PM")
    compare(F.slotTimeLabel({ firstSeconds: 3600, lastSeconds: 3600 }), "1:00 AM")
    var single = F.mergeSlots([takes[2]], range, 600)[0]
    compare(F.slotCallout(single), F.clock(51500) + " · <b>80</b> words")

    compare(F.needleHeight(0, 100), 8)
    compare(F.needleHeight(400, 400), 44)
    compare(F.needleHeight(100, 400), 24)
    verify(F.needleHeight(10, 400) < F.needleHeight(11, 400))
    // A single huge take does not flatten the rest: 400 words against 10000 still reads taller than an empty take.
    verify(F.needleHeight(400, 10000) > 8)
    compare(F.nearestSlot(slots, slots[1].x + 3), 1)
    compare(F.nearestSlot(slots, slots[1].x + 30), -1)
    compare(F.biggestSlot(slots), 1)
    compare(F.biggestSlot([]), -1)
  }
}
