.pragma library
.import "Safe.js" as Safe

// Every hyprctl invocation Vista makes, built in one place. Each returns an
// argv array for Quickshell.execDetached / Process.command: no shell is ever
// involved, and every value placed in Lua has passed Safe validation and is
// Lua-quoted.

var HYPRCTL = "/usr/bin/hyprctl"

function focusWorkspace(id) {
  var ws = Safe.workspaceId(id)
  return ws ? [HYPRCTL, "dispatch", workspaceExpr(ws)] : null
}

// Focus one window, which also switches to its workspace and monitor.
function focusWindow(address) {
  var a = Safe.windowAddress(address)
  return a ? [HYPRCTL, "dispatch", windowExpr(a)] : null
}

// ---------------------------------------------------------------- from the bar
//
// A click or scroll on the workspace strip leaves the pointer on the bar unless
// focus lands on another monitor. One eval turns Hyprland's cursor warps off,
// dispatches, puts the user's values back, and then, only if the focused
// monitor is no longer the bar's, moves the pointer where Hyprland's own warp
// would have (the focused window's centre, else the monitor's), and only if the
// user's settings would have warped at all. The destination is read after the
// dispatch because the strip cannot know it before: workspace rules can send a
// new workspace to another monitor. Any failure to read or set the options
// falls back to a plain dispatch, so a click always switches.

function stayLua(exprs, bar) {
  var lines = []
  for (var i = 0; i < exprs.length; i++) lines.push("  hl.dispatch(" + exprs[i] + ")")
  return [
    "local bar = " + Safe.luaQuote(bar),
    "local function go()",
    lines.join("\n"),
    "end",
    "local get, set = hl.get_config, hl.config",
    "if type(get) ~= \"function\" or type(set) ~= \"function\" then return go() end",
    "local nw, wc = get(\"cursor.no_warps\"), get(\"cursor.warp_on_change_workspace\")",
    "if type(nw) ~= \"boolean\" or type(wc) ~= \"number\" then return go() end",
    "local function put(a, b) return pcall(set, { cursor = { no_warps = a, warp_on_change_workspace = b } }) end",
    "if not put(true, 0) then put(nw, wc) return go() end",
    "local ok, err = pcall(go)",
    "local restored = put(nw, wc)",
    "if not restored or get(\"cursor.no_warps\") ~= nw or get(\"cursor.warp_on_change_workspace\") ~= wc then",
    "  restored = put(nw, wc)",
    "end",
    "if ok and (not nw or wc == 2) then",
    "  pcall(function()",
    "    local m = hl.get_active_monitor()",
    "    if not m or m.name == bar then return end",
    "    local w = hl.get_active_window()",
    "    local x, y",
    "    if w and w.monitor and w.monitor.name == m.name and w.at and w.size then",
    "      x, y = w.at.x + w.size.x / 2, w.at.y + w.size.y / 2",
    "    else",
    "      local s = (m.scale and m.scale > 0) and m.scale or 1",
    "      x, y = m.x + m.width / s / 2, m.y + m.height / s / 2",
    "    end",
    "    hl.dispatch(hl.dsp.cursor.move({ x = x, y = y }))",
    "  end)",
    "end",
    "if not ok then error(\"vista: \" .. tostring(err)) end",
    "if not restored then error(\"vista: could not restore cursor warp options\") end"
  ].join("\n")
}

function stay(exprs, bar) {
  return [HYPRCTL, "eval", stayLua(exprs, bar)]
}

function workspaceExpr(ws) { return "hl.dsp.focus({ workspace = " + Safe.luaQuote(ws) + " })" }
function monitorExpr(mon) { return "hl.dsp.focus({ monitor = " + Safe.luaQuote(mon) + " })" }
function windowExpr(a) { return "hl.dsp.focus({ window = " + Safe.luaQuote("address:" + a) + " })" }

// Show an existing workspace where it lives. Without a known bar monitor, the
// plain dispatch.
function barFocusWorkspace(id, bar) {
  var ws = Safe.workspaceId(id)
  if (!ws) return null
  var mon = Safe.outputName(bar)
  return mon ? stay([workspaceExpr(ws)], mon) : focusWorkspace(ws)
}

// Create a workspace on the bar's monitor (a workspace rule may still send it
// elsewhere). Needs the bar's monitor.
function barFocusWorkspaceOn(id, bar) {
  var ws = Safe.workspaceId(id)
  var mon = Safe.outputName(bar)
  return ws && mon ? stay([monitorExpr(mon), workspaceExpr(ws)], mon) : null
}

// Focus the bar's own monitor.
function barFocusMonitor(bar) {
  var mon = Safe.outputName(bar)
  return mon ? stay([monitorExpr(mon)], mon) : null
}

// Focus one window. Without a known bar monitor, the plain dispatch.
function barFocusWindow(address, bar) {
  var a = Safe.windowAddress(address)
  if (!a) return null
  var mon = Safe.outputName(bar)
  return mon ? stay([windowExpr(a)], mon) : focusWindow(a)
}

// The command for a Strip.pillAction() result from a bar on monitor `bar`.
function barAction(action, id, bar) {
  if (action === "focusMonitor") return barFocusMonitor(bar)
  if (action === "focusWorkspace") return barFocusWorkspace(id, bar)
  if (action === "focusWorkspaceOn") return barFocusWorkspaceOn(id, bar)
  return null
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
function listBinds() { return [HYPRCTL, "binds", "-j"] }
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

// Whether SUPER+TAB and SUPER+SHIFT+TAB reach Vista, from `hyprctl binds -j`.
// Lua binds all report dispatcher "__lua", so Vista's own binds are known by
// the "Vista:" description bindings.lua gives them. Every bind on either key
// must be Vista's: another one there (Omarchy's default, another switcher)
// fires as well. Returns "ok", "missing" (no Vista bind) or "conflict".
var SUPER = 64
var SHIFT = 1

function bindStatus(binds) {
  if (!Array.isArray(binds)) return "ok"   // unreadable: never nag on a guess
  var combos = [SUPER, SUPER | SHIFT]
  var status = "ok"
  for (var c = 0; c < combos.length; c++) {
    var vista = 0
    var other = 0
    for (var i = 0; i < binds.length && i < 5000; i++) {
      var b = binds[i]
      if (!b || typeof b !== "object" || b.modmask !== combos[c] || b.submap) continue
      if (String(b.key || "").toUpperCase() !== "TAB") continue
      if (String(b.description || "").indexOf("Vista:") === 0) vista++
      else other++
    }
    if (vista === 0) return "missing"
    if (other > 0) status = "conflict"
  }
  return status
}
