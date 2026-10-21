.pragma library

// The redesign colours, copied from Sources/MouthtypeMac/Design/DesignPalette.swift (the lime pass, NOT the handoff
// tokens.json). One light set and one dark set. A value is "#RRGGBB", or "#RRGGBB/alpha" for translucent colours.
// test_design.py parses this file, so keep one `name: "value",` pair per line.
//
// Restraint rules from the Mac file: the accent is a fill, never a text colour (text uses accentText); the ring uses
// focus; orange stays out of ordinary UI (lips, streak flame, warnings only). Lime appears only on primary buttons,
// switches when on, focus and chart peaks.

var light = {
  bg: "#F3F3F5",
  surface: "#FFFFFF",
  ink: "#1D1D1F",
  ink2: "#5C5C61",
  ink3: "#6B6B70",
  hair: "#000000/0.12",
  hair2: "#000000/0.07",
  accent: "#76A11A",
  accentSoft: "#76A11A/0.14",
  onAccent: "#1D1D1F",
  accentText: "#4A6A12",
  focus: "#4A6A12",
  orange: "#E37512",
  success: "#537F5D",
  danger: "#D70015",
  gold: "#BB8C1A",
  silver: "#8F939D",
  bronze: "#B8733A",
  personalBest: "#FBE9D3",
  personalBestInk: "#6B3A0A",
  sel: "#000000/0.08",
  c0: "#EFF4E4",
  c1: "#CBDBA8",
  c2: "#76A11A",
  c3: "#5C7E14",
  c4: "#3B4F0E",
  track: "#D9D9DE",
  key: "#FFFFFF",
  scrim: "#000000/0.3",
  sideBase: "#E8E8EC",
  sideInk: "#58585C",
  sideTop: "#A8BACC/0.42",
  sideBottom: "#D6CEC6/0.42",
  shadow: "#000000/0.05"
}

var dark = {
  bg: "#1F1F21",
  surface: "#2A2A2C",
  ink: "#F2F2F2",
  ink2: "#B0B0B5",
  ink3: "#9A9A9F",
  hair: "#FFFFFF/0.14",
  hair2: "#FFFFFF/0.08",
  accent: "#A6CD52",
  accentSoft: "#A6CD52/0.16",
  onAccent: "#1F1F21",
  accentText: "#A6CD52",
  focus: "#A6CD52",
  orange: "#F19A4B",
  success: "#6FA57C",
  danger: "#FF564C",
  gold: "#F2B83D",
  silver: "#C4C6CC",
  bronze: "#D98C4F",
  personalBest: "#3A2B1B",
  personalBestInk: "#F5C28F",
  sel: "#FFFFFF/0.10",
  c0: "#373E2A",
  c1: "#556535",
  c2: "#779041",
  c3: "#A6CD52",
  c4: "#DBEBBA",
  track: "#3C3C40",
  key: "#38383B",
  scrim: "#000000/0.5",
  sideBase: "#19191B",
  sideInk: "#B0B0B5",
  sideTop: "#465C70/0.38",
  sideBottom: "#5C5046/0.38",
  shadow: "#000000/0.3"
}

function color(spec) {
  var parts = spec.split("/")
  var n = parseInt(parts[0].substring(1), 16)
  var alpha = parts.length > 1 ? parseFloat(parts[1]) : 1
  return Qt.rgba(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, alpha)
}

function get(isDark, name) {
  return color((isDark ? dark : light)[name])
}
