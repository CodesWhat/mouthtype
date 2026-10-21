.pragma library

// Pure helpers for the Style page: no QML types, so the Python tests can run them under node and the scenes under Qt.

var TONE_BLURBS = {
  formal: "Sentence case. Keeps your punctuation. Softens swearing.",
  casual: "Sentence case. No full stop at the end.",
  very_casual: "Lowercase starts. No full stop at the end."
}

var NOUNS = { personal: "personal", work: "work", email: "email", other: "other" }

var TONE_EYEBROWS = {
  personal: "Tone for personal messages",
  work: "Tone for work messages",
  email: "Tone for email",
  other: "Tone for everything else"
}

var CLEANUP_HERE = {
  personal: "Set on the Cleanup tab for everything. Change it here only if personal messages should differ.",
  work: "Set on the Cleanup tab for everything. Change it here only if work messages should differ.",
  email: "Set on the Cleanup tab for everything. Long emails are where Thorough earns its keep, if you want it only here.",
  other: "Set on the Cleanup tab for everything. Basic here keeps a model from rewriting a command in a terminal."
}

var LEVELS = ["off", "basic", "fast", "thorough"]
var LEVEL_TITLES = { off: "Off", basic: "Basic", fast: "Fast", thorough: "Thorough" }
var LEVEL_BLURBS = {
  off: "Exactly what you said, mistakes and all.",
  basic: "Fillers, numbers and punctuation. Nothing reworded.",
  fast: "Self-corrections and repeats fixed by a small local model.",
  thorough: "A bigger local model for long, messy takes. Slower."
}
// The same messy take at each level, from the handoff preview. These are illustrations, not output from this machine.
var LEVEL_SAMPLES = {
  off: "um so can we move the sync to like ten no eleven tomorrow I I want to finish the the pill sizing first",
  basic: "So can we move the sync to 10, no, 11 tomorrow? I I want to finish the the pill sizing first.",
  fast: "So can we move the sync to 11 tomorrow? I want to finish the pill sizing first.",
  thorough: "Can we move the sync to 11 tomorrow? I want to finish the pill sizing first."
}

function levelTitle(level) { return LEVEL_TITLES[level] || "" }

function toneTitle(tones, id) {
  for (var i = 0; i < (tones || []).length; i++) if (tones[i].id === id) return tones[i].title
  return ""
}

// ---- Sample diff -----------------------------------------------------------------------------------------------------

// Which characters of `styled` the tone added to what was `spoken`: those outside a longest common subsequence of the two. A capital
// that replaced a lowercase letter counts as added, like the comma and full stop do.
function addedMask(spoken, styled) {
  var a = String(spoken), b = String(styled)
  var n = a.length, m = b.length
  var table = []
  for (var i = 0; i <= n; i++) {
    var row = []
    for (var j = 0; j <= m; j++) row.push(0)
    table.push(row)
  }
  for (i = n - 1; i >= 0; i--) {
    for (j = m - 1; j >= 0; j--) {
      table[i][j] = a.charAt(i) === b.charAt(j) ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1])
    }
  }
  var mask = []
  for (j = 0; j < m; j++) mask.push(true)
  i = 0; j = 0
  while (i < n && j < m) {
    if (a.charAt(i) === b.charAt(j)) { mask[j] = false; i++; j++ }
    else if (table[i + 1][j] >= table[i][j + 1]) i++
    else j++
  }
  return mask
}

// [{ text, added }] runs of `styled`.
function segments(spoken, styled) {
  var mask = addedMask(spoken, styled)
  var out = []
  var text = String(styled)
  for (var i = 0; i < text.length; i++) {
    var last = out.length ? out[out.length - 1] : null
    if (last && last.added === mask[i]) last.text += text.charAt(i)
    else out.push({ text: text.charAt(i), added: mask[i] })
  }
  return out
}

// Character index ranges [start, end) of the added runs.
function ranges(segs) {
  var out = []
  var at = 0
  for (var i = 0; i < segs.length; i++) {
    if (segs[i].added) out.push({ start: at, end: at + segs[i].text.length })
    at += segs[i].text.length
  }
  return out
}

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Rich text with the added runs on a background. `tint` is a CSS colour. Spaces are kept as typed: the engine hands back
// single spaces, and a run of spaces would collapse in rich text.
function markup(segs, tint, ink) {
  var out = ""
  for (var i = 0; i < segs.length; i++) {
    var piece = escapeHtml(segs[i].text)
    out += segs[i].added ? '<span style="background-color:' + tint + '; color:' + ink + '">' + piece + "</span>" : piece
  }
  return out
}

function plain(segs) {
  var out = ""
  for (var i = 0; i < segs.length; i++) out += segs[i].text
  return out
}

// ---- Members and rules -----------------------------------------------------------------------------------------------

function sameClass(a, b) { return String(a).toLowerCase() === String(b).toLowerCase() }

// The per-app rule that covers a member: the first rule on any of its window classes.
function ruleFor(rules, apps) {
  for (var i = 0; i < (rules || []).length; i++) {
    for (var j = 0; j < (apps || []).length; j++) if (sameClass(rules[i].app, apps[j])) return rules[i]
  }
  return null
}

// Rules on apps that no list holds. Those show on the Other tab as "Your own rules".
function ownRules(state) {
  var out = []
  var contexts = (state && state.contexts) || []
  var rules = (state && state.rules) || []
  for (var i = 0; i < rules.length; i++) {
    var listed = false
    for (var c = 0; c < contexts.length && !listed; c++) {
      var members = contexts[c].members || []
      for (var m = 0; m < members.length && !listed; m++) listed = ruleFor([rules[i]], members[m].apps) !== null
    }
    if (!listed) out.push(rules[i])
  }
  return out
}

function ownRuleCount(state) {
  var rules = (state && state.rules) || []
  var count = 0
  for (var i = 0; i < rules.length; i++) if (rules[i].cleanup) count++
  return count
}

// Popup choices. Index 0 is always "same as", so a choice maps back by position: tone ids and level ids below.
var TONE_IDS = [null, "formal", "casual", "very_casual"]
var LEVEL_IDS = [null, "off", "basic", "fast", "thorough"]

function toneChoices(sameLabel, tones) {
  var out = [sameLabel]
  for (var i = 1; i < TONE_IDS.length; i++) out.push(toneTitle(tones, TONE_IDS[i]) || TONE_IDS[i])
  return out
}

function levelChoices(sameLabel) {
  var out = [sameLabel]
  for (var i = 1; i < LEVEL_IDS.length; i++) out.push(LEVEL_TITLES[LEVEL_IDS[i]])
  return out
}

function toneIndex(id) { var at = TONE_IDS.indexOf(id === undefined ? null : id); return at < 0 ? 0 : at }
function levelIndex(id) { var at = LEVEL_IDS.indexOf(id === undefined ? null : id); return at < 0 ? 0 : at }

// "Same as personal · Casual" when the context sets one, "Same as personal" when it falls through.
function sameAs(noun, title) { return "Same as " + noun + (title ? " · " + title : "") }

// The control.py requests that set one field of a member's rule. A built-in can ship under several window classes, so every
// class gets the same rule. The other field keeps what the rule already holds. Both ending up unset removes the rule.
function ruleRequests(member, rule, field, value) {
  var tone = rule ? rule.tone : null
  var cleanup = rule ? rule.cleanup : null
  if (field === "tone") tone = value
  else cleanup = value
  var out = []
  var apps = member.apps || []
  var seen = {}
  for (var i = 0; i < apps.length; i++) {
    var key = apps[i].toLowerCase()
    if (seen[key]) continue
    seen[key] = true
    out.push(["style-rule", [apps[i], tone || "none", cleanup || "none", member.name]])
  }
  return out
}

function removeRuleRequest(rule) { return ["style-rule", [rule.app, "none", "none", rule.name || ""]] }

// "" when the window class can be sent, otherwise a sentence for the add row. The backend checks the same things.
function classProblem(text) {
  var value = String(text)
  if (value.trim() === "") return "Enter a window class."
  if (value !== value.trim()) return "Remove the spaces around the window class."
  if (value.length > 128) return "A window class is up to 128 characters."
  if (value.indexOf("*") >= 0) return "A window class has to be exact, without wildcards."
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if (code < 32 || code === 127) return "A window class has no control characters."
  }
  return ""
}

// ---- Cleanup tab -----------------------------------------------------------------------------------------------------

function followText(contexts, globalLevel) {
  var following = []
  for (var i = 0; i < contexts.length; i++) if (!contexts[i].cleanup) following.push(contexts[i].title)
  if (following.length === 0) return "Every context sets its own level."
  var list = following.length > 1 ? following.slice(0, -1).join(", ") + " and " + following[following.length - 1] : following[0]
  return list + " use " + levelTitle(globalLevel) + ", the level above."
}

function followCount(contexts) {
  var n = 0
  for (var i = 0; i < contexts.length; i++) if (!contexts[i].cleanup) n++
  return n
}

// Status line for one level card. `models` is state.cleanup.models, `service` is state.cleanup.service.
function levelStatus(level, models, service, setup) {
  if (level === "off" || level === "basic") return "NO MODEL · INSTANT"
  if (setup && setup.level === level && (setup.state === "preparing" || setup.state === "building" || setup.state === "downloading")) return "PREPARING"
  if (setup && setup.level === level && setup.state === "failed") return "PREPARE FAILED"
  if (!models || models[level] !== "prepared") return "NOT PREPARED"
  if (service && service.level === level && service.model) {
    if (service.model.state === "ready") return "READY"
    if (service.model.state === "loading") return "LOADING"
    if (service.model.state === "failed") return "FAILED"
  }
  return "PREPARED · LOADS WHEN NEEDED"
}
