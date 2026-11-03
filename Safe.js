.pragma library

// Input validation shared by the switcher (Service.qml) and its settings
// panel (Settings.qml). Everything that did not come from this plugin's own
// literals is treated as input: settings from shell.json, monitor names from
// EDID, window titles and classes, and hyprctl output.

var MAX_WORKSPACE = 50
var MAX_PINS = 50
var MAX_MONITOR_KEY = 256
var MAX_TITLE = 256

// C0/C1 controls, line/paragraph separators, BOM, and bidi marks and overrides.
var CONTROL = /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]/g

// A workspace id as a string of 1..MAX_WORKSPACE, or "" when it is not one.
function workspaceId(value) {
  var s = String(value)
  if (!/^[1-9][0-9]?$/.test(s)) return ""
  return Number(s) <= MAX_WORKSPACE ? s : ""
}

// Monitor keys are "desc:<EDID description>" or an output name like "HDMI-A-1".
function monitorKey(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_MONITOR_KEY) return ""
  if (/[\u0000-\u001f\u007f"\\]/.test(value)) return ""
  if (value.indexOf("desc:") === 0) return value.length > 5 ? value : ""
  return /^[A-Za-z0-9._-]{1,64}$/.test(value) ? value : ""
}

// A monitor's output (connector) name such as "HDMI-A-1", or "".
function outputName(value) {
  return typeof value === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(value) ? value : ""
}

// A Hyprland window address as "0x<lowercase hex>", or "". Quickshell reports
// it as bare hex, hyprctl with a 0x prefix; both are accepted. Only a string of
// 1..16 hex digits passes, so nothing else can reach a Lua string.
function windowAddress(value) {
  if (typeof value !== "string") return ""
  var m = /^(?:0[xX])?([0-9A-Fa-f]{1,16})$/.exec(value)
  return m ? "0x" + m[1].toLowerCase().replace(/^0+(?=.)/, "") : ""
}

// The pins setting reduced to valid entries: workspace id -> monitor key.
// Null-prototype map, so keys like "__proto__" are just keys.
function pins(value) {
  var out = Object.create(null)
  if (!value || typeof value !== "object" || Array.isArray(value)) return out
  var n = 0
  var seen = 0
  for (var k in value) {
    // Bound the walk itself, not only the result: the object is input.
    if (++seen > MAX_PINS * 4 || n >= MAX_PINS) break
    if (!Object.prototype.hasOwnProperty.call(value, k)) continue
    var id = workspaceId(k)
    var key = monitorKey(value[k])
    if (!id || !key) continue
    out[id] = key
    n++
  }
  return out
}

// A Lua string literal. Only ever given values that already passed
// monitorKey() or workspaceId() and matched a closed allowlist.
function luaQuote(s) {
  return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
}

// Cuts s to at most max UTF-16 units without splitting a surrogate pair.
function cut(s, max) {
  if (s.length <= max) return s
  var out = s.slice(0, max)
  var last = out.charCodeAt(out.length - 1)
  return last >= 0xd800 && last <= 0xdbff ? out.slice(0, -1) : out
}

// Text for host components the plugin cannot pin to PlainText (tooltips):
// no markup characters, no control or bidi characters, capped.
function plain(value, max) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(CONTROL, "").replace(/[<>&]/g, "")
  return cut(s, max || 64)
}

// A window title for a PlainText label: controls removed, capped.
function title(value) {
  var s = String(value === undefined || value === null ? "" : value).replace(CONTROL, "")
  return cut(s, MAX_TITLE)
}

// A window class usable as an icon-theme or desktop-entry name, or "".
function appClass(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return /^[A-Za-z0-9._-]{1,128}$/.test(s) && s !== "." && s !== ".." ? s : ""
}
