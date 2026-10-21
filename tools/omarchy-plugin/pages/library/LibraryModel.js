.pragma library

// Pure helpers for the Dictionary and Transforms pages. No QML imports, so node runs them (test_library_model.py).

var PREVIEW_ROWS = 6

// Most rows a list page builds at once. Every row is a handful of items made synchronously, so an unbounded list froze the
// shell for seconds at 1000 entries and for tens of seconds at the 5000 a CSV import allows. "Show more" adds another batch.
var PAGE_ROWS = 120

// A reply the shell published after `before` was read. Every request stores a freshly parsed object.
function isFresh(reply, before) {
  return reply !== undefined && reply !== null && reply !== before
}

function libraryFrom(reply, kind) {
  return reply && reply.kind === kind && Array.isArray(reply.entries) ? reply : null
}

// True when any write reply says the library file was created and linux.json now names it. The running service read its
// paths at start, so it needs a restart before it applies the new file.
function adoptedConfig(results, verbs) {
  for (var i = 0; i < verbs.length; i++) {
    var reply = results ? results[verbs[i]] : null
    if (reply && reply.adopted_config === true) return true
  }
  return false
}

// Spellings grouped by written form, in order of first appearance. Each form keeps its saved pairs so a row can edit one.
function groupSpellings(entries) {
  var groups = []
  var index = Object.create(null)
  for (var i = 0; i < (entries || []).length; i++) {
    var entry = entries[i]
    var at = index[entry.written]
    if (at === undefined) {
      at = groups.length
      index[entry.written] = at
      groups.push({ written: entry.written, starred: false, pairs: [], warnings: [] })
    }
    var group = groups[at]
    group.pairs.push(entry)
    if (entry.starred === true) group.starred = true
    if (entry.warning) group.warnings.push(entry.warning)
  }
  return groups
}

// The cap to use after fresh library data lands. A small expansion survives a reload or an edit so the user keeps their place;
// a large one resets, because rebuilding every revealed row at once is the freeze the cap exists to prevent.
function capAfterReload(shown) {
  return shown <= PAGE_ROWS * 2 ? shown : PAGE_ROWS
}

// The groups whose written form or any heard form contains the query, case-insensitive. An empty query keeps them all.
function filterGroups(groups, query) {
  var needle = String(query || "").trim().toLowerCase()
  if (needle === "") return groups
  var found = []
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    var hit = group.written.toLowerCase().indexOf(needle) !== -1
    for (var j = 0; !hit && j < group.pairs.length; j++) hit = String(group.pairs[j].heard).toLowerCase().indexOf(needle) !== -1
    if (hit) found.push(group)
  }
  return found
}

function oneLine(text) {
  return String(text || "").replace(/\r\n|\r|\n/g, " ⏎ ")
}

function lineCount(text) {
  var value = String(text || "")
  return value === "" ? 0 : value.split(/\r\n|\r|\n/).length
}

function variables(text) {
  var found = Object.create(null)
  var pattern = /\{([A-Za-z_]+)\}/g
  var match
  while ((match = pattern.exec(String(text || ""))) !== null) found[match[1].toLowerCase()] = true
  return found
}

// TEXT, n LINES, CLIPBOARD or DATE. A variable wins over the line count; clipboard wins over date.
function kindTag(expansion) {
  var found = variables(expansion)
  if (found.clipboard) return "CLIPBOARD"
  if (found.date) return "DATE"
  var lines = lineCount(expansion)
  return lines > 1 ? lines + " LINES" : "TEXT"
}

var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

// The long English date the service writes for {date}.
function longDate(now) {
  var d = now || new Date()
  return MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear()
}

// What a row shows after the arrow: a bare variable reads as a description, anything else as the typed text on one line.
function previewText(expansion, now) {
  var bare = String(expansion || "").trim().toLowerCase()
  if (bare === "{clipboard}") return "Whatever you copied before you started talking"
  if (bare === "{date}") return "Today\u2019s date, like " + longDate(now)
  return oneLine(expansion)
}

// Insert `snippet` at the cursor, replacing the selection. Returns the new text and where the cursor goes.
function insertAt(text, start, end, snippet) {
  var value = String(text || "")
  var from = Math.max(0, Math.min(start, end, value.length))
  var to = Math.max(from, Math.min(Math.max(start, end), value.length))
  return { text: value.slice(0, from) + snippet + value.slice(to), cursor: from + snippet.length }
}

// The Import sheet's rows: the first PREVIEW_ROWS plus every invalid row, in file order, and how many are left out.
function visibleImportRows(rows) {
  var shown = []
  for (var i = 0; i < (rows || []).length; i++) {
    if (i < PREVIEW_ROWS || rows[i].result === "invalid") shown.push(rows[i])
  }
  return { shown: shown, hidden: (rows || []).length - shown.length }
}

function plural(count, one, many) {
  return count === 1 ? one : many
}

// Parts of the summary line: [{ count, label, bad }] for new, already saved, duplicates (only if any) and errors.
function importSummary(counts) {
  var c = counts || {}
  var parts = [
    { count: c.add || 0, label: "new", bad: false },
    { count: c.existing || 0, label: "already saved", bad: false }
  ]
  if ((c.duplicate || 0) > 0) parts.push({ count: c.duplicate, label: "duplicate", bad: false })
  parts.push({ count: c.invalid || 0, label: plural(c.invalid || 0, "error", "errors"), bad: (c.invalid || 0) > 0 })
  return parts
}

function importButtonText(counts) {
  var n = counts && counts.add ? counts.add : 0
  return "Import " + n + " " + plural(n, "spelling", "spellings")
}

// Why Import is off, or "" when it is allowed. The page also gates on preview.can_import.
function importBlockedReason(preview) {
  if (!preview) return ""
  if (preview.problem) return preview.problem
  var counts = preview.counts || {}
  if ((counts.invalid || 0) > 0) {
    return "Fix the " + plural(counts.invalid, "error", "errors") + " in the file, then choose it again."
  }
  if ((counts.add || 0) === 0) return "Every row is already saved, so there is nothing to import."
  return ""
}

function importFootnote(preview) {
  var reason = importBlockedReason(preview)
  return "Nothing changes until you import." + (reason !== "" ? " " + reason : "")
}

// "THOROUGH · READY" and friends for the On selected text rows. `status` is the transform-status reply, or null while unknown.
function modelStatus(kind, status) {
  if (!kind || kind.needs_model === false) return { text: "NO MODEL · INSTANT", ready: false }
  if (!status || !status.model) return { text: "THOROUGH · CHECKING", ready: false }
  var state = status.model.state
  var words = { ready: "READY", absent: "NOT PREPARED", unconfigured: "NOT SET UP", unsupported: "NOT SUPPORTED", unreadable: "CAN’T READ SETTINGS", unavailable: "UNAVAILABLE" }
  return { text: "THOROUGH · " + (words[state] || String(state || "UNKNOWN").toUpperCase()), ready: state === "ready" }
}

// The five transforms as the Mac lists them, shown until transform-status answers.
var FALLBACK_KINDS = [
  { id: "clean-up", title: "Clean up", description: "Spoken commands and spacing. No model.", needs_model: false },
  { id: "fix-grammar", title: "Fix grammar", description: "Spelling, punctuation and capitalization. Keeps your wording.", needs_model: true },
  { id: "make-shorter", title: "Make shorter", description: "Cuts words that add nothing. Keeps every fact.", needs_model: true },
  { id: "more-formal", title: "More formal", description: "Professional register: no slang, no contractions.", needs_model: true },
  { id: "more-casual", title: "More casual", description: "Conversational register with contractions.", needs_model: true }
]

function transformKinds(status) {
  return status && Array.isArray(status.kinds) && status.kinds.length ? status.kinds : FALLBACK_KINDS
}

// The reason line under the On selected text card: the first unavailable AI kind's reason, "" when all are available.
function modelReason(status) {
  if (status && status.error) return String(status.error)
  var kinds = status && Array.isArray(status.kinds) ? status.kinds : []
  for (var i = 0; i < kinds.length; i++) if (kinds[i].reason) return kinds[i].reason
  return ""
}
