.pragma library

// Display strings and tape geometry for the Stats page, ported from StatsFormat.swift and StatsPage.swift. Pure functions so
// the render tests can call them directly. Nothing here shortens text.

var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var dot = " · "

function number(n) {
  var v = Math.round(Number(n) || 0)
  return (v < 0 ? "-" : "") + String(Math.abs(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// "2:04 PM" from seconds since local midnight.
function clock(seconds) {
  var hour = Math.floor(seconds / 3600) % 24
  var minute = Math.floor((seconds % 3600) / 60)
  return (hour % 12 === 0 ? 12 : hour % 12) + ":" + (minute < 10 ? "0" : "") + minute + " " + (hour < 12 ? "AM" : "PM")
}

// "2 PM", "12 AM".
function hourName(hour) {
  var h = ((hour % 24) + 24) % 24
  return (h % 12 === 0 ? 12 : h % 12) + " " + (h < 12 ? "AM" : "PM")
}

// "88 hours you didn't have to type." Under an hour it counts minutes; with nothing saved it says so.
function savedHeadline(minutes) {
  var total = Math.round(minutes || 0)
  if (total < 1) return "Nothing saved yet."
  if (total < 60) return total + (total === 1 ? " minute" : " minutes") + " you didn't have to type."
  var hours = Math.round(minutes / 60)
  return number(hours) + (hours === 1 ? " hour" : " hours") + " you didn't have to type."
}

// "22 h 10 min" from a minute count. "0 min" when empty.
function talkingMinutes(minutes) {
  var total = Math.round(minutes || 0)
  var h = Math.floor(total / 60), m = total % 60
  return h === 0 ? m + " min" : h + " h " + m + " min"
}

// "12 min 48 s", or "" when there is no duration.
function speaking(ms) {
  if (ms === null || ms === undefined || !(ms > 0)) return ""
  var seconds = Math.round(ms / 1000)
  return seconds >= 60 ? Math.floor(seconds / 60) + " min " + (seconds % 60) + " s" : seconds + " s"
}

function talkingMs(ms) { return speaking(ms) || "0 s" }

function days(n) { return n === 1 ? "1 day" : n + " days" }

function dayParts(day) {
  var parts = String(day).split("-").map(function(p) { return parseInt(p, 10) })
  return parts.length === 3 && parts[1] >= 1 && parts[1] <= 12 && !isNaN(parts[0]) && !isNaN(parts[2]) ? parts : null
}

// "2026-10-03" as "Oct 3, 2026". A malformed day is shown as stored.
function date(day) {
  var p = dayParts(day)
  return p ? months[p[1] - 1] + " " + p[2] + ", " + p[0] : String(day)
}

function shortDay(day) {
  var p = dayParts(day)
  return p ? months[p[1] - 1] + " " + p[2] : String(day)
}

// "Oct 9" this year, "Oct 9, 2025" otherwise.
function recordDate(day, today) {
  return String(day).slice(0, 4) === String(today).slice(0, 4) ? shortDay(day) : date(day)
}

// The meter segment holding `value`, 0-based, over `segments` segments spanning 0 to `top`. -1 for no value.
function meterSegment(value, segments, top) {
  if (value === null || value === undefined || !(value > 0)) return -1
  var width = top / segments
  return Math.min(segments - 1, Math.max(0, Math.ceil(value / width) - 1))
}

// "4× a typist." style, or "" when slower than 1.5 times typing.
function typistRatio(wpm, typingWpm) {
  if (wpm === null || wpm === undefined || !(typingWpm > 0) || wpm / typingWpm < 1.5) return ""
  var ratio = Math.round(wpm / typingWpm * 10) / 10
  return (ratio === Math.round(ratio) ? String(ratio) : ratio.toFixed(1)) + "× a typist."
}

function wpmText(value) { return value === null || value === undefined ? "none" : String(Math.round(value)) }

// ---- Today's tape ----

var minimumHours = 3
var minimumSpacing = 6
var maximumNeedle = 44

// The hours the tape spans: a little before the first take (or now, if earlier) to a little after now or the last take, never
// less than three hours.
function tapeRange(takes, nowSeconds) {
  var seconds = takes.map(function(t) { return t.seconds_into_day })
  var first = Math.min(seconds.length ? Math.min.apply(null, seconds) : nowSeconds, nowSeconds)
  var last = Math.max(seconds.length ? Math.max.apply(null, seconds) : 0, nowSeconds)
  var lower = Math.max(0, Math.floor((first - 15 * 60) / 3600))
  var upper = Math.min(24, Math.floor((last + 10 * 60 + 3599) / 3600))
  if (upper - lower < minimumHours) {
    upper = Math.min(24, lower + minimumHours)
    lower = Math.max(0, upper - minimumHours)
  }
  var hours = upper - lower
  var step = hours <= 6 ? 1 : (hours <= 12 ? 2 : (hours <= 18 ? 3 : 4))
  var ticks = []
  for (var h = lower; h < upper; h += step) ticks.push(h)
  return { start: lower, end: upper, span: hours * 3600, ticks: ticks }
}

function fraction(range, seconds) {
  return Math.min(1, Math.max(0, (seconds - range.start * 3600) / range.span))
}

function tickLabel(hour, edge) {
  if (hour === 12) return "NOON"
  if (edge) return hourName(hour)
  return String(hour % 12 === 0 ? 12 : hour % 12)
}

// Takes in time order, grouped so no two needles start closer than minSpacing points apart at this width. Each slot sits where
// its first take falls and its words are the sum. `hollow` counts audio-only takes in the slot.
function mergeSlots(takes, range, width, minSpacing) {
  var spacing = minSpacing === undefined ? minimumSpacing : minSpacing
  var sorted = takes.slice().sort(function(a, b) { return a.seconds_into_day - b.seconds_into_day })
  var slots = []
  for (var i = 0; i < sorted.length; i++) {
    var take = sorted[i]
    var x = width * fraction(range, take.seconds_into_day)
    var last = slots.length ? slots[slots.length - 1] : null
    if (last && x - last.x < spacing) {
      last.count += 1
      last.words += take.words
      last.hollow += take.audio_only ? 1 : 0
      last.lastSeconds = take.seconds_into_day
      last.take = null
    } else {
      slots.push({ x: x, count: 1, words: take.words, hollow: take.audio_only ? 1 : 0,
                   firstSeconds: take.seconds_into_day, lastSeconds: take.seconds_into_day, take: take })
    }
  }
  return slots
}

// Square-root scale so one long take doesn't flatten the rest. Still strictly taller for more words.
function needleHeight(words, maxWords) {
  if (!(words > 0)) return 8
  return 4 + (maximumNeedle - 4) * Math.sqrt(words / Math.max(1, maxWords))
}

// "2:50 to 2:58 PM", or just "2:50 PM" for one moment.
function slotTimeLabel(slot) {
  var first = clock(slot.firstSeconds), last = clock(slot.lastSeconds)
  if (first === last) return first
  return (first.slice(-2) === last.slice(-2) ? first.slice(0, -3) : first) + " to " + last
}

// "3 takes · 412 words · 2:50 to 2:58 PM".
function slotSummary(slot) {
  var text = slot.count + (slot.count === 1 ? " take" : " takes") + dot + number(slot.words) + " words" + dot + slotTimeLabel(slot)
  if (slot.hollow > 0) text += dot + slot.hollow + " audio only"
  return text
}

// The callout for a needle: one take reads "2:04 PM · 412 words · 12 s", a merged slot reads its summary.
function slotCallout(slot) {
  if (slot.take) {
    var tail = speaking(slot.take.duration_ms)
    return clock(slot.take.seconds_into_day) + dot + "<b>" + number(slot.take.words) + "</b> words" + (tail ? dot + tail : "")
  }
  return slotSummary(slot)
}

// Index of the slot nearest x within the merge distance, or -1.
function nearestSlot(slots, x) {
  var best = -1
  for (var i = 0; i < slots.length; i++) {
    if (best < 0 || Math.abs(slots[i].x - x) < Math.abs(slots[best].x - x)) best = i
  }
  return best >= 0 && Math.abs(slots[best].x - x) <= minimumSpacing ? best : -1
}

// The slot with the most words, or -1.
function biggestSlot(slots) {
  var best = -1
  for (var i = 0; i < slots.length; i++) {
    if (slots[i].words > 0 && (best < 0 || slots[i].words > slots[best].words)) best = i
  }
  return best
}
