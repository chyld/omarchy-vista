.pragma library

// Input validation shared by the switcher (Service.qml) and its settings
// panel (Settings.qml). Everything that did not come from this plugin's own
// literals is treated as input: settings from shell.json, monitor names from
// EDID, window titles and classes, and hyprctl output.

var MAX_WORKSPACE = 50
var MAX_PINS = 50
var MAX_MONITOR_KEY = 256
var MAX_TITLE = 256

var CONTROL = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g

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

// The pins setting reduced to valid entries: workspace id -> monitor key.
// Null-prototype map, so keys like "__proto__" are just keys.
function pins(value) {
  var out = Object.create(null)
  if (!value || typeof value !== "object" || Array.isArray(value)) return out
  var n = 0
  for (var k in value) {
    if (!Object.prototype.hasOwnProperty.call(value, k)) continue
    if (n >= MAX_PINS) break
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

// Text for host components the plugin cannot pin to PlainText (tooltips):
// no markup characters, no control or bidi characters, capped.
function plain(value, max) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(CONTROL, "").replace(/[<>&]/g, "")
  var cap = max || 64
  return s.length > cap ? s.slice(0, cap) : s
}

// A window title for a PlainText label: controls removed, capped.
function title(value) {
  var s = String(value === undefined || value === null ? "" : value).replace(CONTROL, "")
  return s.length > MAX_TITLE ? s.slice(0, MAX_TITLE) : s
}

// A window class usable as an icon-theme or desktop-entry name, or "".
function appClass(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return /^[A-Za-z0-9._-]{1,128}$/.test(s) && s !== "." && s !== ".." ? s : ""
}
