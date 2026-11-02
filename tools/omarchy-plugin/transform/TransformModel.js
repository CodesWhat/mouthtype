.pragma library

// Everything the Transform Selection panel decides, as plain functions over one session object, so the panel stays a
// view and the logic can be exercised without Quickshell. A session is what the panel knows about the current capture:
//
//   phase     closed | starting | running | ready | accepting | done | error
//   id, app   the capture id and { class, name, pid, address } from the `transform-capture` reply
//   original  the captured text; result is what the editor starts with; serverResult is the last model or cleanup output
//   diff      the backend's { highlight, reason, limit, original, result } spans for original -> serverResult
//   kind      the active transform id; kinds the chips from `transform-status`
//   refused   null, or { title, detail } after Accept was refused
//
// Reducers return a new object and never mutate their input. Replies are the JSON objects documented in
// tools/linux-desktop/cli_transform.py; a reply with only an `error` string comes from control.py itself.

var DIFF_LIMIT = 2000
var MAX_CELLS = 1500000

var KINDS = [
  { id: "clean-up", title: "Clean up", model: false },
  { id: "fix-grammar", title: "Fix grammar", model: true },
  { id: "make-shorter", title: "Make shorter", model: true },
  { id: "more-formal", title: "More formal", model: true },
  { id: "more-casual", title: "More casual", model: true }
]

function kindInfo(id) {
  for (var i = 0; i < KINDS.length; i++) if (KINDS[i].id === id) return KINDS[i]
  return null
}

function placeholderKinds() {
  var out = []
  for (var i = 0; i < KINDS.length; i++) out.push({ id: KINDS[i].id, title: KINDS[i].title, available: true, reason: null })
  return out
}

function merge(base, patch) {
  var out = {}
  var key
  for (key in base) out[key] = base[key]
  for (key in patch) out[key] = patch[key]
  return out
}

function empty() {
  return {
    phase: "closed", id: "", app: null, original: "", result: "", serverResult: "", serial: 0, diff: null,
    kind: "clean-up", previousKind: "clean-up", failedKind: "", kinds: placeholderKinds(), modelNote: "",
    message: "", messageTone: "info", refused: null, submitted: false, source: "primary", fallback: false
  }
}

function fail(reply, fallback) {
  if (reply && typeof reply.message === "string" && reply.message !== "") return reply.message
  if (reply && typeof reply.reason === "string" && reply.reason !== "") return reply.reason
  if (reply && typeof reply.error === "string" && reply.error !== "") return reply.error
  return fallback
}

function appName(session) {
  return session.app && session.app.name ? String(session.app.name) : ""
}

function isBusy(session) {
  return session.phase === "starting" || session.phase === "running" || session.phase === "accepting"
}

function isModelKind(id) {
  var info = kindInfo(id)
  return info !== null && info.model
}

// ---- reducers ---------------------------------------------------------------------------------------------------

// The reply of `transform-capture`, or the file `transform-open` wrote (the same object plus opened_at).
function fromCapture(reply) {
  if (!reply || reply.state !== "captured" || typeof reply.id !== "string" || typeof reply.text !== "string")
    return merge(empty(), { phase: "error", message: fail(reply, "Transform Selection is unavailable."), messageTone: "error" })
  return merge(empty(), {
    phase: "starting", id: reply.id, app: reply.app || null, original: reply.text, source: reply.source || "primary",
    fallback: reply.fallback === true,
    message: reply.fallback === true ? "Nothing was selected, so this is your clipboard." : ""
  })
}

function withStatus(session, status) {
  if (!status || status.state !== "status" || !status.kinds) return session
  var kinds = []
  for (var i = 0; i < status.kinds.length; i++) {
    var item = status.kinds[i]
    kinds.push({ id: item.id, title: item.title, available: item.available === true, reason: item.reason || null })
  }
  var model = status.model || {}
  return merge(session, { kinds: kinds, modelNote: model.state && model.state !== "ready" ? String(model.reason || "") : "" })
}

function runStarted(session, kind) {
  return merge(session, { phase: "running", previousKind: session.kind, failedKind: "", kind: kind, refused: null, message: "" })
}

function absorbRun(session, reply) {
  if (reply && reply.state === "ready") {
    return merge(session, {
      phase: "ready", kind: reply.kind, result: reply.text, serverResult: reply.text, serial: session.serial + 1,
      diff: reply.diff || null, message: reply.message || "", messageTone: "info", refused: null
    })
  }
  var note = session.modelNote
  if (reply && reply.state === "unavailable") note = fail(reply, note)
  if (reply && reply.state === "cancelled")
    return merge(session, { phase: "ready", kind: session.previousKind, message: "Cancelled.", messageTone: "info" })
  return merge(session, {
    phase: "ready", kind: session.previousKind, failedKind: session.kind, modelNote: note,
    message: reply && reply.state === "unavailable" ? "" : fail(reply, "That transform failed. Retry, or cancel."),
    messageTone: "error"
  })
}

function accepting(session) {
  return merge(session, { phase: "accepting", message: "" })
}

function refusedTitle(session) {
  var name = appName(session)
  return name !== "" ? "Mouthtype didn't replace the text in " + name + "." : "Mouthtype didn't replace the text."
}

function absorbAccept(session, reply) {
  if (reply && reply.state === "requested")
    return merge(session, { phase: "done", submitted: true, message: reply.message || "Replacement requested.", messageTone: "info" })
  if (reply && reply.state === "refused")
    return merge(session, { phase: "ready", refused: { title: refusedTitle(session), detail: fail(reply, "") }, message: "" })
  if (reply && reply.state === "cancelled") return merge(session, { phase: "ready", message: "Cancelled.", messageTone: "info" })
  return merge(session, { phase: "ready", message: fail(reply, "The replacement failed."), messageTone: "error" })
}

function absorbCopy(session, reply) {
  if (reply && reply.state === "copied")
    return merge(session, { message: reply.what === "original" ? "Copied the original." : "Copied the result.", messageTone: "info" })
  return merge(session, { message: fail(reply, "Couldn't copy."), messageTone: "error" })
}

// ---- derived view state -----------------------------------------------------------------------------------------

function chips(session) {
  var out = []
  var locked = isBusy(session) || session.phase === "error" || session.phase === "done" || session.refused !== null
  for (var i = 0; i < session.kinds.length; i++) {
    var item = session.kinds[i]
    out.push({
      id: item.id, title: item.title, active: item.id === session.kind && session.phase !== "error",
      enabled: !locked && item.available, reason: item.reason
    })
  }
  return out
}

// Retry shows while an AI transform is the active choice, and works once it has finished.
function retryKind(session) {
  return session.failedKind ? session.failedKind : session.kind
}

function retryVisible(session) {
  return session.phase !== "error" && isModelKind(retryKind(session))
}

function canRetry(session) {
  return retryVisible(session) && session.phase === "ready" && session.refused === null && !session.submitted
}

function canAccept(session, text) {
  return session.phase === "ready" && session.refused === null && !session.submitted && String(text).trim() !== ""
}

function canCopy(session, text) {
  return !isBusy(session) && session.phase !== "error" && String(text).trim() !== ""
}

function busyText(session) {
  if (session.phase === "starting") return "Getting ready…"
  if (session.phase === "accepting") return "Replacing the selection…"
  var info = kindInfo(session.kind)
  if (session.phase !== "running" || !info) return ""
  return info.model ? info.title + " is running on the local model…" : "Cleaning up…"
}

function highlightNote(session) {
  return session.diff && session.diff.highlight === false
    ? "Highlighting is off for text over 2,000 characters." : ""
}

// ---- diff -------------------------------------------------------------------------------------------------------

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g, "<br>")
}

// Original text as rich text, with the removed segments struck through in the muted colour.
function originalHtml(segments, mutedColor) {
  var html = ""
  for (var i = 0; i < segments.length; i++) {
    var text = escapeHtml(segments[i].text)
    html += segments[i].kind === "removed" ? '<s><span style="color:' + mutedColor + '">' + text + "</span></s>" : text
  }
  return '<div style="white-space: pre-wrap">' + html + "</div>"
}

function plain(text) {
  return text === "" ? [] : [{ text: text, kind: "equal" }]
}

function tokens(text) {
  var out = []
  var previous = ""
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    var kind = /\s/.test(c) ? "s" : /[0-9A-Za-z_ªµºÀ-῿Ⰰ-퟿豈-￯]/.test(c) ? "w" : "o"
    if (kind !== "o" && kind === previous) out[out.length - 1] += c
    else out.push(c)
    previous = kind
  }
  return out
}

function pushMerged(list, kind, text) {
  if (text === "") return
  if (list.length && list[list.length - 1].kind === kind) list[list.length - 1].text += text
  else list.push({ text: text, kind: kind })
}

// The same shape as the backend's diff_segments, for text the user has edited: word-level LCS over tokens. Either side
// over DIFF_LIMIT characters, or a table too large to fill quickly, returns unmarked text and highlight false.
function clientDiff(original, result) {
  if (original.length > DIFF_LIMIT || result.length > DIFF_LIMIT)
    return { highlight: false, reason: "over_limit", limit: DIFF_LIMIT, original: plain(original), result: plain(result) }
  var a = tokens(original)
  var b = tokens(result)
  var n = a.length
  var m = b.length
  if ((n + 1) * (m + 1) > MAX_CELLS)
    return { highlight: false, reason: "over_limit", limit: DIFF_LIMIT, original: plain(original), result: plain(result) }
  var width = m + 1
  var table = new Uint16Array((n + 1) * width)
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      table[i * width + j] = a[i] === b[j] ? table[(i + 1) * width + j + 1] + 1
        : Math.max(table[(i + 1) * width + j], table[i * width + j + 1])
    }
  }
  var before = []
  var after = []
  var x = 0
  var y = 0
  while (x < n || y < m) {
    if (x < n && y < m && a[x] === b[y]) {
      pushMerged(before, "equal", a[x])
      pushMerged(after, "equal", b[y])
      x++; y++
    } else if (y >= m || (x < n && table[(x + 1) * width + y] >= table[x * width + y + 1])) {
      pushMerged(before, "removed", a[x])
      x++
    } else {
      pushMerged(after, "added", b[y])
      y++
    }
  }
  return { highlight: true, reason: null, limit: DIFF_LIMIT, original: before, result: after }
}

// The diff to draw for the text now in the editor: the backend's while it is untouched, a fresh one once edited.
function diffFor(session, text) {
  if (session.diff && text === session.serverResult) return session.diff
  if (text === "") return { highlight: true, reason: null, limit: DIFF_LIMIT, original: plain(session.original), result: [] }
  return clientDiff(session.original, text)
}

// [start, end) offsets of the added segments in the result text.
function addedRanges(diff) {
  var out = []
  if (!diff || diff.highlight === false) return out
  var at = 0
  for (var i = 0; i < diff.result.length; i++) {
    var end = at + diff.result[i].text.length
    if (diff.result[i].kind === "added" && end > at) out.push([at, end])
    at = end
  }
  return out
}
