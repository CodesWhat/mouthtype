.pragma library

// Level-to-meter maths ported from the Mac pill's BarModel and MeterAdapter: a dBFS reading becomes a 0..1
// fraction between a slowly adapting floor and ceiling with a soft knee, then ten columns read it at staggered
// delays, scaled by fixed weights, with a fast attack and a short release.

var BAR_COUNT = 10
var SEGMENT_ROWS = 5
var FLOOR_DB = -120

var WEIGHTS = (function() {
  var raw = [], peak = 0
  for (var i = 0; i < BAR_COUNT; i++) {
    raw.push(0.3 + 0.7 * Math.cos(Math.PI * Math.abs(i - 4.5) / BAR_COUNT))
    peak = Math.max(peak, raw[i])
  }
  return raw.map(function(w) { return w / peak })
})()
var DELAYS = (function() { var d = []; for (var i = 0; i < BAR_COUNT; i++) d.push(Math.abs(i - 4.5) * 0.018); return d })()
var ATTACK = 0.025, RELEASE = 0.07, RELEASE_SPREAD = 0.01, SETTLE = 0.002, KNEE = 0.75

function fraction(db, floor, ceiling) {
  if (!isFinite(db) || ceiling <= floor) return 0
  var x = (db - floor) / (ceiling - floor)
  if (x <= 0) return 0
  if (x <= KNEE) return x
  return KNEE + (1 - KNEE) * Math.tanh((x - KNEE) / (1 - KNEE))
}

function Adapter() {
  this.noiseDb = -58; this.loudDb = -30
  this.windowMin = Infinity; this.previousWindowMin = Infinity; this.windowAge = 0
}
Adapter.prototype.floorDb = function() { return Math.min(Math.max(this.noiseDb + 3, -55), -45) }
Adapter.prototype.ceilingDb = function() {
  return Math.max(this.floorDb() + 12, Math.min(Math.max(this.loudDb + 18, -30), -6))
}
Adapter.prototype.update = function(db, dt) {
  if (dt <= 0) return
  this.windowMin = Math.min(this.windowMin, db)
  this.windowAge += dt
  if (this.windowAge >= 4) { this.previousWindowMin = this.windowMin; this.windowMin = Infinity; this.windowAge = 0 }
  var seen = Math.min(this.windowMin, this.previousWindowMin)
  var target = Math.min(-42, Math.max(-75, seen))
  var tau = target < this.noiseDb ? 0.5 : 2.5
  this.noiseDb += (target - this.noiseDb) * (1 - Math.exp(-dt / tau))
  if (db <= this.floorDb() + 8) return
  var loudTau = db > this.loudDb ? 5 : 2.5
  this.loudDb += (db - this.loudDb) * (1 - Math.exp(-dt / loudTau))
}

function Meter() {
  this.adapter = new Adapter()
  this.smoothed = []; for (var i = 0; i < BAR_COUNT; i++) this.smoothed.push(0)
  this.history = []
}
Meter.prototype.reset = function() { this.smoothed = this.smoothed.map(function() { return 0 }); this.history = [] }
Meter.prototype.delayed = function(delay) {
  for (var i = this.history.length - 1; i >= 0; i--) if (this.history[i].age >= delay) return this.history[i].db
  return this.history.length ? this.history[0].db : FLOOR_DB
}
Meter.prototype.step = function(db, dt) {
  dt = isFinite(dt) ? Math.max(0, dt) : 0
  db = isFinite(db) ? Math.min(0, Math.max(FLOOR_DB, db)) : FLOOR_DB
  this.adapter.update(db, dt)
  for (var h = 0; h < this.history.length; h++) this.history[h].age += dt
  this.history.push({ age: 0, db: db })
  var keep = DELAYS[DELAYS.length - 1] + 0.05
  this.history = this.history.filter(function(e) { return e.age <= keep })
  var floor = this.adapter.floorDb(), ceiling = this.adapter.ceilingDb()
  for (var i = 0; i < BAR_COUNT; i++) {
    var target = fraction(this.delayed(DELAYS[i]), floor, ceiling) * WEIGHTS[i]
    var distance = Math.abs(i - 4.5) - 0.5
    var tau = target > this.smoothed[i] ? ATTACK : RELEASE + RELEASE_SPREAD * distance
    var alpha = 1 - Math.exp(-dt / tau)
    this.smoothed[i] += (target - this.smoothed[i]) * alpha
    if (this.smoothed[i] < SETTLE && target === 0) this.smoothed[i] = 0
  }
  return this.smoothed.slice()
}

// Whole segments to light per column, 1..rows: the baseline segment is always lit.
function litSegments(fractions, rows) {
  return fractions.map(function(f) {
    f = isFinite(f) ? Math.min(1, Math.max(0, f)) : 0
    return Math.min(rows, Math.max(1, Math.ceil(f * rows - 0.01)))
  })
}

// Processing: a low slow wave along the classic bars.
function processingFractions(time) {
  var out = []
  for (var i = 0; i < BAR_COUNT; i++) out.push(0.2 + 0.1 * Math.sin(2 * Math.PI * (time * 0.8 - i * 0.09)))
  return out
}

// Processing on the segmented skin: a three-column run travelling back and forth along the middle row.
function processingColumns(time) {
  var period = 2 * (BAR_COUNT - 1)
  var step = Math.floor(Math.max(0, time) * 12) % period
  var centre = step < BAR_COUNT ? step : period - step
  return [Math.max(0, centre - 1), Math.min(BAR_COUNT - 1, centre + 1)]
}

function timerText(seconds) {
  var s = Math.min(Math.max(0, Math.floor(seconds)), 9 * 60 + 59)
  var rest = s % 60
  return Math.floor(s / 60) + ":" + (rest < 10 ? "0" : "") + rest
}

function ledOn(elapsed, locked) {
  if (!locked) return true
  return Math.floor(Math.max(0, elapsed) * 2) % 2 === 0
}

// What the pill says once a take settles. Coarse codes only; no transcript text ever reaches the pill.
function message(snapshot, deliveryMode) {
  var error = snapshot.error, delivery = snapshot.delivery
  if (error === "recording_limit") return { headline: "Too long", detail: "Saved to recovery", isError: true }
  if (error === "capture_interrupted") return { headline: "Microphone lost", detail: "Audio saved", isError: true }
  if (error === "capture_unavailable") return { headline: "No microphone", detail: "Check PipeWire", isError: true }
  if (error === "transcription_failed") return { headline: "Couldn't transcribe", detail: "Audio saved for retry", isError: true }
  if (error === "recovery_full") return { headline: "Recovery is full", detail: "Forget old takes first", isError: true }
  if (error && /unavailable/.test(error)) return { headline: "Needs attention", detail: String(error).replace(/_/g, " "), isError: true }
  if (delivery === "unknown") return { headline: deliveryMode === "type" ? "Typed" : "Pasted", detail: "Check the field", isError: false }
  if (delivery === "recover_only") return { headline: "Saved", detail: deliveryMode === "recover" ? null : "App not allowed", isError: false }
  if (delivery === "target_changed") return { headline: "Window changed", detail: "Saved to recovery", isError: false }
  if (delivery === "unsupported_text") return { headline: "Saved", detail: "Text can't be typed here", isError: false }
  if (delivery === "empty") return { headline: "Nothing heard", detail: null, isError: false }
  return null
}
