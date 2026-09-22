.pragma library
.import "Safe.js" as Safe

// Every hyprctl invocation Vista makes, built in one place. Each returns an
// argv array for Quickshell.execDetached / Process.command: no shell is ever
// involved, and every value placed in Lua has passed Safe validation and is
// Lua-quoted.

var HYPRCTL = "/usr/bin/hyprctl"

function focusWorkspace(id) {
  var ws = Safe.workspaceId(id)
  return ws ? [HYPRCTL, "dispatch", "hl.dsp.focus({ workspace = " + Safe.luaQuote(ws) + " })"] : null
}

function moveWorkspace(id, monitor) {
  var ws = Safe.workspaceId(id)
  var mon = Safe.monitorKey(monitor)
  return ws && mon
    ? [HYPRCTL, "dispatch", "hl.dsp.workspace.move({ workspace = " + Safe.luaQuote(ws) + ", monitor = " + Safe.luaQuote(mon) + " })"]
    : null
}

// One workspace rule per pin, in a single eval. `pins` must already be
// validated and limited to connected monitors.
function workspaceRules(pins) {
  var lua = []
  for (var id in pins) {
    var ws = Safe.workspaceId(id)
    var mon = Safe.monitorKey(pins[id])
    if (ws && mon) lua.push("hl.workspace_rule({ workspace = " + Safe.luaQuote(ws) + ", monitor = " + Safe.luaQuote(mon) + " })")
  }
  return lua.length ? [HYPRCTL, "eval", lua.join("\n")] : null
}

function reload() { return [HYPRCTL, "reload"] }
function listWorkspaceRules() { return [HYPRCTL, "workspacerules", "-j"] }
function superIsDown() {
  return [HYPRCTL, "eval", 'error(tostring(hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
}

// The key a pin stores for a monitor: its EDID description when Hyprland has
// reported it (stable across ports), else its output name.
function monitorKey(monitor) {
  if (!monitor) return ""
  var ipc = monitor.lastIpcObject || {}
  return (ipc.description ? Safe.monitorKey("desc:" + ipc.description) : "")
    || Safe.monitorKey(String(monitor.name || ""))
}

// Every key that identifies a monitor, so a pin saved either way matches.
function monitorKeys(monitor) {
  var keys = []
  if (!monitor) return keys
  var ipc = monitor.lastIpcObject || {}
  var byDesc = ipc.description ? Safe.monitorKey("desc:" + ipc.description) : ""
  var byName = Safe.monitorKey(String(monitor.name || ""))
  if (byDesc) keys.push(byDesc)
  if (byName) keys.push(byName)
  return keys
}

// A short, plain label for a monitor. The model name comes from EDID.
function monitorLabel(monitor) {
  if (!monitor) return ""
  var name = String(monitor.name || "")
  if (name.indexOf("eDP") === 0) return "Laptop"
  var ipc = monitor.lastIpcObject || {}
  return Safe.plain(ipc.model || name, 24) || Safe.plain(name, 24)
}
