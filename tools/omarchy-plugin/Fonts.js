.pragma library

// One text font preference for Mouthtype's own menu, transcript card and classic pill, with optional per-role
// overrides. Generic family names resolve through fontconfig. Nothing here affects the font an application uses
// for inserted text.

var PRESETS = ["default", "sans", "serif", "mono", "custom"]
var ROLES = ["menu", "transcript", "pill"]

function normalize(prefs) {
  var font = prefs && prefs.font && typeof prefs.font === "object" ? prefs.font : {}
  var overrides = font.overrides && typeof font.overrides === "object" ? font.overrides : {}
  var clean = {}
  for (var i = 0; i < ROLES.length; i++) clean[ROLES[i]] = typeof overrides[ROLES[i]] === "string" ? overrides[ROLES[i]] : ""
  return {
    preset: PRESETS.indexOf(font.preset) !== -1 ? font.preset : "default",
    family: typeof font.family === "string" ? font.family : "",
    overrides: clean,
  }
}

function presetTitle(preset) {
  switch (preset) {
    case "sans": return "Sans"
    case "serif": return "Serif"
    case "mono": return "Mono"
    case "custom": return "Custom"
    default: return "Default"
  }
}

function presetFamily(font, fallback) {
  switch (font.preset) {
    case "sans": return "sans-serif"
    case "serif": return "serif"
    case "mono": return "monospace"
    case "custom": return font.family || fallback
    default: return fallback
  }
}

// The family for a role: its override when set, else the preset.
function family(prefs, role, fallback) {
  var font = normalize(prefs)
  if (font.overrides[role]) return font.overrides[role]
  return presetFamily(font, fallback)
}

function summary(prefs) {
  var font = normalize(prefs)
  var base = font.preset === "custom" ? (font.family || "Custom") : presetTitle(font.preset)
  var count = 0
  for (var role in font.overrides) if (font.overrides[role]) count++
  return count ? base + " +" + count : base
}
