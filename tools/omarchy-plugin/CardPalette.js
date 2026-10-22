.pragma library

// Delivery-card colours for the pill's settled message, mirroring CardPalette.swift and SquirclePalette.swift. Two styles:
// "classic" is the dark capsule the Classic pill wears in both appearances; "minimal" follows light and dark and is the
// only one that carries lime, on the single primary action. The accent is a fill, never a text colour: text on lime is
// primaryText. primaryEdge is a 1px ring on the primary button where lime sits on a light body (about 1.4:1), "" when none. Minimal's lime takes dark ink, so hover and press lighten it (more contrast) where Classic's darken.
//
// Plain "#RRGGBB" strings plus separate alphas, so test_pill.py can read this file without Qt.

var CLASSIC = {
  style: "classic", dark: true,
  bodyTop: "#1A1A1A", bodyBottom: "#1A1A1A", bodyAlpha: 0.96,
  border: "#4D4A42", borderAlpha: 1,
  text: "#FFFFEB", error: "#FF6B5E", detailAlpha: 0.62,
  warn: "#FF453A", quiet: "#F4F3E8", rec: "#FF453A",
  showsDot: true, radius: 14,
  primaryFill: "#F4F3E8", primaryText: "#1D1D1F", primaryLightens: false, primaryEdge: "",
  tint: "#808080", tintRest: 0.18, tintHover: 0.30, tintPress: 0.42, secondaryText: "#F1F0E6"
}

var MINIMAL_DARK = {
  style: "minimal", dark: true,
  bodyTop: "#252528", bodyBottom: "#19191B", bodyAlpha: 1,
  border: "#FFFFFF", borderAlpha: 0.15,
  text: "#F4F3E8", error: "#FF6B5E", detailAlpha: 0.62,
  warn: "#FF6B5E", quiet: "#F4F3E8", rec: "#FF453A",
  showsDot: false, radius: 14,
  primaryFill: "#D3E58B", primaryText: "#1F1F21", primaryLightens: true, primaryEdge: "",
  tint: "#FFFFFF", tintRest: 0.10, tintHover: 0.16, tintPress: 0.24, secondaryText: "#F1F0E6"
}

var MINIMAL_LIGHT = {
  style: "minimal", dark: false,
  bodyTop: "#FBFBFC", bodyBottom: "#F0F0F3", bodyAlpha: 1,
  border: "#000000", borderAlpha: 0.16,
  text: "#1D1D1F", error: "#D70015", detailAlpha: 0.72,
  warn: "#D70015", quiet: "#1D1D1F", rec: "#E0281C",
  showsDot: false, radius: 14,
  primaryFill: "#D3E58B", primaryText: "#1D1D1F", primaryLightens: true, primaryEdge: "#4A6A12",
  tint: "#000000", tintRest: 0.07, tintHover: 0.12, tintPress: 0.18, secondaryText: "#1D1D1F"
}

// `style` is "classic" or "minimal"; anything else is classic. Classic ignores `dark`.
function palette(style, dark) {
  if (style === "minimal") return dark ? MINIMAL_DARK : MINIMAL_LIGHT
  return CLASSIC
}

function parse(hex) {
  return [parseInt(hex.substr(1, 2), 16), parseInt(hex.substr(3, 2), 16), parseInt(hex.substr(5, 2), 16)]
}

function toHex(rgb) {
  var out = "#"
  for (var i = 0; i < 3; i++) {
    var v = Math.max(0, Math.min(255, Math.round(rgb[i])))
    out += (v < 16 ? "0" : "") + v.toString(16).toUpperCase()
  }
  return out
}

// `fraction` of the way from `hex` towards `target`.
function blend(hex, target, fraction) {
  var a = parse(hex), b = parse(target)
  return toHex([a[0] + (b[0] - a[0]) * fraction, a[1] + (b[1] - a[1]) * fraction, a[2] + (b[2] - a[2]) * fraction])
}

// "#AARRGGBB" for a colour at an alpha, which QML reads as a colour.
function withAlpha(hex, alpha) {
  var a = Math.max(0, Math.min(255, Math.round(alpha * 255)))
  return "#" + (a < 16 ? "0" : "") + a.toString(16).toUpperCase() + hex.substr(1)
}

// The primary button's fill for a state. Minimal lightens on hover and press; Classic brightens on hover and darkens on press.
function primaryFill(p, hovered, pressed) {
  if (p.primaryLightens) return blend(p.primaryFill, "#FFFFFF", pressed ? 0.40 : hovered ? 0.25 : 0)
  return pressed ? blend(p.primaryFill, "#000000", 0.18) : hovered ? blend(p.primaryFill, "#FFFFFF", 0.5) : p.primaryFill
}

function tintFill(p, hovered, pressed) {
  return withAlpha(p.tint, pressed ? p.tintPress : hovered ? p.tintHover : p.tintRest)
}

// The dot and headline colours for a settled message: errors wear the warning red, good news the quiet ink.
function dotColor(p, isError) { return isError ? p.warn : p.quiet }
function headlineColor(p, isError) { return isError ? p.error : p.text }
