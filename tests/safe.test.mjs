// Unit tests for Safe.js, Hypr.js and Omarchy.js, the code every untrusted value passes
// through. Run with: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, existsSync } from "node:fs"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = fileURLToPath(new URL("..", import.meta.url))

// QML JavaScript libraries start with ".pragma" / ".import" lines, which are
// not JavaScript; drop them and evaluate the rest in a sandbox.
function load(file, globals = {}) {
  const src = readFileSync(root + file, "utf8").replace(/^\.(pragma|import) .*$/gm, "")
  const context = vm.createContext({ ...globals })
  vm.runInContext(src, context)
  return context
}

const Safe = load("Safe.js")
const Hypr = load("Hypr.js", { Safe })
const Omarchy = load("Omarchy.js")

test("workspaceId accepts 1..50 only", () => {
  assert.equal(Safe.workspaceId(1), "1")
  assert.equal(Safe.workspaceId("50"), "50")
  for (const bad of [0, 51, -1, "01", "1.5", "1e1", "", null, undefined, "__proto__", "3 ", "\n3"])
    assert.equal(Safe.workspaceId(bad), "", String(bad))
})

test("monitorKey accepts desc: descriptions and output names", () => {
  assert.equal(Safe.monitorKey("HDMI-A-1"), "HDMI-A-1")
  assert.equal(Safe.monitorKey("desc:Example Corp 27in ABC123"), "desc:Example Corp 27in ABC123")
  for (const bad of ["", "desc:", "HDMI A 1", 'desc:a"b', "desc:a\\b", "desc:a\nb", "x".repeat(65),
                     "desc:" + "x".repeat(300), 42, null, { toString: () => "HDMI-A-1" }])
    assert.equal(Safe.monitorKey(bad), "", JSON.stringify(bad))
})

test("pins keeps only valid entries in a null-prototype map", () => {
  const out = Safe.pins({ "1": "HDMI-A-1", "2": "desc:Panel", "0": "HDMI-A-1", "x": "HDMI-A-1",
                          "3": 'bad"quote', "__proto__": "HDMI-A-1", "4": 7 })
  assert.deepEqual(Object.keys(out).sort(), ["1", "2"])
  assert.equal(Object.getPrototypeOf(out), null)
  for (const bad of [null, [], "x", 3]) assert.deepEqual(Object.keys(Safe.pins(bad)), [])
})

test("pins bounds the walk over a huge object", () => {
  const huge = {}
  for (let i = 0; i < 100000; i++) huge["junk" + i] = "HDMI-A-1"
  huge["1"] = "HDMI-A-1"   // integer-like keys enumerate first in JS
  assert.deepEqual(Object.keys(Safe.pins(huge)), ["1"])
})

test("pins caps the number of entries", () => {
  const many = {}
  for (let i = 1; i <= 50; i++) many[String(i)] = "HDMI-A-1"
  many["extra"] = "HDMI-A-1"
  assert.equal(Object.keys(Safe.pins(many)).length, Safe.MAX_PINS)
})

test("luaQuote escapes backslashes and quotes", () => {
  assert.equal(Safe.luaQuote('a"b\\c'), '"a\\"b\\\\c"')
})

test("plain strips markup, controls and bidi, and caps length", () => {
  assert.equal(Safe.plain('<img src="x">&amp;'), 'img src="x"amp;')
  assert.equal(Safe.plain("a\u0000b‮c\u0007"), "abc")
  assert.equal(Safe.plain("x".repeat(100), 10), "x".repeat(10))
  assert.equal(Safe.plain(null), "")
})

test("plain and title never cut a surrogate pair in half", () => {
  const s = "ab\u{1F600}cd"   // a, b, then a two-unit emoji
  assert.equal(Safe.plain(s, 3), "ab")
  assert.equal(Safe.plain(s, 4), "ab\u{1F600}")
  assert.equal(Safe.title("x".repeat(255) + "\u{1F600}").length, 255)
})

test("plain and title strip separators, BOM and bidi marks", () => {
  const s = "a\u2028b\u2029c\ufeffd\u061ce\u202ef"
  assert.equal(Safe.plain(s), "abcdef")
  assert.equal(Safe.title(s), "abcdef")
})

test("title removes controls and caps at 256", () => {
  assert.equal(Safe.title("tab\tname\n"), "tabname")
  assert.equal(Safe.title("x".repeat(1000)).length, Safe.MAX_TITLE)
})

test("appClass accepts plain names only", () => {
  assert.equal(Safe.appClass("org.mozilla.firefox"), "org.mozilla.firefox")
  for (const bad of ["", ".", "..", "a/b", "../x", "a b", "x".repeat(129), null])
    assert.equal(Safe.appClass(bad), "", String(bad))
})

test("hyprctl commands are argv arrays with validated, quoted values", () => {
  assert.deepEqual(Array.from(Hypr.focusWorkspace(3)),
    ["/usr/bin/hyprctl", "dispatch", 'hl.dsp.focus({ workspace = "3" })'])
  assert.deepEqual(Array.from(Hypr.moveWorkspace("2", "desc:Panel")),
    ["/usr/bin/hyprctl", "dispatch", 'hl.dsp.workspace.move({ workspace = "2", monitor = "desc:Panel" })'])
  assert.equal(Hypr.focusWorkspace("3) os.execute('x') --"), null)
  assert.equal(Hypr.moveWorkspace("2", 'x", monitor = "y'), null)
})

test("windowAddress accepts 1..16 hex digits, with or without 0x, normalised", () => {
  assert.equal(Safe.windowAddress("556e062addd0"), "0x556e062addd0")
  assert.equal(Safe.windowAddress("0x556E062ADDD0"), "0x556e062addd0")
  assert.equal(Safe.windowAddress("0X1a"), "0x1a")
  assert.equal(Safe.windowAddress("000a"), "0xa")
  assert.equal(Safe.windowAddress("0"), "0x0")
  assert.equal(Safe.windowAddress("f".repeat(16)), "0x" + "f".repeat(16))
  assert.equal(Safe.windowAddress("0x" + "A".repeat(16)), "0x" + "a".repeat(16))
  assert.equal(Safe.windowAddress("0x" + "a".repeat(17)), "")
  for (const bad of ["", "0x", "address:0x1", "0x0x1", "f".repeat(17), "0xg1", " 0x1", "0x1 ", "0x1\n",
                     '0x1"', "0x1'", "-1", 0x1234, 12, null, undefined, { toString: () => "0x1" }])
    assert.equal(Safe.windowAddress(bad), "", JSON.stringify(bad))
})

test("outputName accepts connector names only", () => {
  assert.equal(Safe.outputName("HDMI-A-1"), "HDMI-A-1")
  assert.equal(Safe.outputName("eDP-1"), "eDP-1")
  for (const bad of ["", "desc:Panel", "HDMI A 1", 'a"b', "a\\b", "x".repeat(65), 1, null, { toString: () => "eDP-1" }])
    assert.equal(Safe.outputName(bad), "", JSON.stringify(bad))
})

test("focusWindow is a plain dispatch of a validated address", () => {
  assert.deepEqual(Array.from(Hypr.focusWindow("556e062addd0")),
    ["/usr/bin/hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:0x556e062addd0" })'])
  assert.equal(Hypr.focusWindow('0x1" }) os.execute("x") --'), null)
  assert.equal(Hypr.focusWindow("address:0x1"), null)
})

// The body of go() in a bar eval: the dispatches, one per line.
function goBody(lua) {
  const m = /\nlocal function go\(\)\n([\s\S]*?)\nend\n/.exec(lua)
  return m ? m[1].split("\n").map(l => l.trim()) : null
}

test("bar commands dispatch inside one eval that keeps the pointer", () => {
  const cases = [
    [Hypr.barFocusWorkspace(3, "HDMI-A-1"), "HDMI-A-1", ['hl.dispatch(hl.dsp.focus({ workspace = "3" }))']],
    [Hypr.barFocusMonitor("eDP-1"), "eDP-1", ['hl.dispatch(hl.dsp.focus({ monitor = "eDP-1" }))']],
    [Hypr.barFocusWorkspaceOn(4, "eDP-1"), "eDP-1",
      ['hl.dispatch(hl.dsp.focus({ monitor = "eDP-1" }))', 'hl.dispatch(hl.dsp.focus({ workspace = "4" }))']],
    [Hypr.barFocusWindow("556e062addd0", "HDMI-A-1"), "HDMI-A-1",
      ['hl.dispatch(hl.dsp.focus({ window = "address:0x556e062addd0" }))']],
  ]
  for (const [argv, bar, dispatches] of cases) {
    assert.equal(argv.length, 3)
    assert.equal(argv[0], "/usr/bin/hyprctl")
    assert.equal(argv[1], "eval")
    const lua = argv[2]
    assert.ok(lua.startsWith(`local bar = "${bar}"\n`), lua)
    assert.deepEqual(goBody(lua), dispatches)
    // A bare dispatcher does nothing in an eval: every focus is inside hl.dispatch.
    assert.ok(!/^\s*hl\.dsp\./m.test(lua), "bare dispatcher")
    // Falls back to a plain dispatch when the options can't be read or set.
    assert.match(lua, /if type\(get\) ~= "function" or type\(set\) ~= "function" then return go\(\) end/)
    assert.match(lua, /if type\(nw\) ~= "boolean" or \(type\(wc\) ~= "number" and type\(wc\) ~= "boolean"\) then return go\(\) end/)
    assert.match(lua, /if not put\(true, 0\) then put\(nw, wc\) return go\(\) end/)
    // The dispatch runs under pcall, and the user's own values are what is restored.
    assert.match(lua, /\nlocal ok, err = pcall\(go\)\nlocal restored = put\(nw, wc\) and same\(\)\n/)
    // The retry is read back too.
    assert.match(lua, /\nif not restored then restored = put\(nw, wc\) and same\(\) end\n/)
    assert.match(lua, /local function same\(\) return read\("cursor\.no_warps"\) == nw and read\("cursor\.warp_on_change_workspace"\) == wc end/)
    // Every option read is protected: a throwing getter can't stop the click.
    assert.ok(!/[^.]\bget\("cursor/.test(lua), "unprotected read")
    assert.ok(!/put\(false|put\(nw, 1\)|warp_on_change_workspace = 1/.test(lua), "literal restore")
    // The pointer is moved only after landing on another monitor, and only if
    // the user's settings would have warped.
    const byWorkspace = /workspace = /.test(dispatches.join(" "))
    assert.ok(lua.includes(byWorkspace
      ? "\nif ok and (wc == 2 or (not nw and wc ~= 0 and wc ~= false)) then\n"
      : "\nif ok and (not nw or wc == 2) then\n"), "warp condition")
    assert.match(lua, /if not m or m\.name == bar then return end/)
    assert.match(lua, /error\("vista: " \.\. tostring\(err\)\)/)
  }
})

// The generated Lua compiles, when a Lua compiler is installed.
const luac = ["/usr/bin/luac", "/usr/bin/luac5.4"].find(p => existsSync(p))
test("bar commands are valid Lua", { skip: luac ? false : "no luac installed" }, () => {
  for (const argv of [Hypr.barFocusWorkspace(3, "HDMI-A-1"), Hypr.barFocusMonitor("eDP-1"),
                      Hypr.barFocusWorkspaceOn(4, "eDP-1"), Hypr.barFocusWindow("0x1a", "eDP-1")]) {
    const r = spawnSync(luac, ["-p", "-"], { input: argv[2], encoding: "utf8" })
    assert.equal(r.status, 0, r.stderr)
  }
})

// Runs a bar eval under a stand-in `hl` and reports what it did.
const lua = ["/usr/bin/lua5.4", "/usr/bin/lua", "/usr/bin/lua5.5"].find(p => existsSync(p))
function simulate(code, opts = {}) {
  const o = { nw: false, wc: 1, active: "eDP-1", window: null, failConfig: false, failDispatch: false,
              failGet: "never", silentRestore: false, ...opts }
  const lit = v => v === null ? "nil" : typeof v === "string" ? JSON.stringify(v) : String(v)
  const win = o.window
    ? `{ at = { x = ${o.window.x}, y = ${o.window.y} }, size = { x = ${o.window.w}, y = ${o.window.h} }, monitor = { name = ${lit(o.window.monitor)} } }`
    : "nil"
  const harness = `
local state = { nw = ${lit(o.nw)}, wc = ${lit(o.wc)} }
local focused, moves, writes, reads = {}, {}, 0, 0
local monitors = {
  ["eDP-1"] = { name = "eDP-1", x = 0, y = 0, width = 2880, height = 1620, scale = 2 },
  ["HDMI-A-1"] = { name = "HDMI-A-1", x = 1440, y = 0, width = 3840, height = 2160, scale = 2 },
}
hl = {
  get_config = function(k)
    reads = reads + 1
    if ${lit(o.failGet)} == "always" or (${lit(o.failGet)} == "after" and writes > 0) then error("get failed") end
    if k == "cursor.no_warps" then return state.nw end
    if k == "cursor.warp_on_change_workspace" then return state.wc end
  end,
  config = function(t)
    if ${o.failConfig} then error("config refused") end
    writes = writes + 1
    if ${o.silentRestore} and writes > 1 then return end
    if t.cursor.no_warps ~= nil then state.nw = t.cursor.no_warps end
    if t.cursor.warp_on_change_workspace ~= nil then state.wc = t.cursor.warp_on_change_workspace end
  end,
  dispatch = function(d)
    if d.move then moves[#moves + 1] = d.move.x .. "," .. d.move.y return end
    if ${o.failDispatch} then error("dispatch failed") end
    focused[#focused + 1] = tostring(state.nw) .. "/" .. tostring(state.wc)
  end,
  dsp = { focus = function(a) return { focus = a } end, cursor = { move = function(a) return { move = a } end } },
  get_active_monitor = function() return monitors[${lit(o.active)}] end,
  get_active_window = function() return ${win} end,
}
local ok, err = pcall(function()
${code}
end)
print(table.concat({ tostring(ok), tostring(state.nw), tostring(state.wc), table.concat(focused, " "), table.concat(moves, " "), tostring(writes), ok and "" or tostring(err) }, "|"))
`
  const r = spawnSync(lua, ["-"], { input: harness, encoding: "utf8" })
  assert.equal(r.status, 0, r.stderr)
  const [ok, nw, wc, focusedUnder, moves, writes, err] = r.stdout.trim().split("|")
  return { ok: ok === "true", nw, wc, focusedUnder, moves, writes: Number(writes), err }
}

test("bar evals behave as specified (simulated hl)", { skip: lua ? false : "no lua installed" }, () => {
  const ws = Hypr.barFocusWorkspace(3, "eDP-1")[2]
  const on = Hypr.barFocusWorkspaceOn(4, "eDP-1")[2]

  // Lands on the bar's monitor: dispatched with warps off, restored, no move.
  let r = simulate(ws, { active: "eDP-1" })
  assert.deepEqual([r.ok, r.nw, r.wc, r.focusedUnder, r.moves], [true, "false", "1", "true/0", ""])
  r = simulate(on, { active: "eDP-1" })
  assert.equal(r.focusedUnder, "true/0 true/0")
  assert.equal(r.moves, "")

  // Lands elsewhere: the pointer goes to the focused window there, else the monitor's centre.
  r = simulate(on, { active: "HDMI-A-1" })
  assert.equal(r.moves, "2400,540")
  r = simulate(ws, { active: "HDMI-A-1", window: { x: 1452, y: 38, w: 1896, h: 1031, monitor: "HDMI-A-1" } })
  assert.equal(r.moves, "2400,554")
  // A focused window on another monitor is not used.
  r = simulate(ws, { active: "HDMI-A-1", window: { x: 10, y: 10, w: 100, h: 100, monitor: "eDP-1" } })
  assert.equal(r.moves, "2400,540")

  // The user's own warp settings decide whether it moves at all.
  assert.equal(simulate(ws, { active: "HDMI-A-1", nw: true, wc: 1 }).moves, "")
  assert.equal(simulate(ws, { active: "HDMI-A-1", nw: true, wc: 2 }).moves, "2400,540")
  r = simulate(ws, { active: "HDMI-A-1", nw: true, wc: 2 })
  assert.deepEqual([r.nw, r.wc], ["true", "2"])

  // A workspace change moves the pointer only if Hyprland's workspace warp is
  // on; a window focus only if no_warps is off.
  const win = Hypr.barFocusWindow("0x1a", "eDP-1")[2]
  assert.equal(simulate(ws, { active: "HDMI-A-1", wc: 0 }).moves, "")
  assert.equal(simulate(ws, { active: "HDMI-A-1", wc: false }).moves, "")
  assert.equal(simulate(ws, { active: "HDMI-A-1", wc: true }).moves, "2400,540")
  assert.equal(simulate(win, { active: "HDMI-A-1", wc: 0 }).moves, "2400,540")
  assert.equal(simulate(win, { active: "HDMI-A-1", nw: true, wc: 1 }).moves, "")
  assert.equal(simulate(win, { active: "eDP-1" }).moves, "")

  // Focusing the bar's own monitor never moves the pointer.
  const mon = Hypr.barFocusMonitor("eDP-1")[2]
  r = simulate(mon, { active: "eDP-1" })
  assert.deepEqual([r.ok, r.nw, r.wc, r.focusedUnder, r.moves], [true, "false", "1", "true/0", ""])
  // No active monitor reported: no move, still restored.
  r = simulate(ws, { active: "none" })
  assert.deepEqual([r.ok, r.nw, r.wc, r.moves], [true, "false", "1", ""])

  // A boolean warp_on_change_workspace is kept and restored as it was.
  r = simulate(ws, { wc: true })
  assert.deepEqual([r.ok, r.nw, r.wc, r.focusedUnder], [true, "false", "true", "true/0"])

  // Options that can't be read, or a config that refuses, still switch.
  r = simulate(ws, { nw: null })
  assert.deepEqual([r.ok, r.focusedUnder, r.writes], [true, "nil/1", 0])
  r = simulate(ws, { failConfig: true })
  assert.deepEqual([r.ok, r.nw, r.wc, r.focusedUnder], [true, "false", "1", "false/1"])

  // A getter that throws: still a plain switch.
  r = simulate(ws, { failGet: "always" })
  assert.deepEqual([r.ok, r.focusedUnder, r.writes], [true, "false/1", 0])
  // A getter that throws on the read-back: the restore is reported as failed.
  r = simulate(ws, { failGet: "after" })
  assert.equal(r.ok, false)
  assert.match(r.err, /could not restore/)
  // Restores that return normally but don't apply are caught, not reported as success.
  r = simulate(ws, { silentRestore: true })
  assert.equal(r.ok, false)
  assert.match(r.err, /could not restore/)

  // A failing dispatch still restores, and reports the error.
  r = simulate(ws, { failDispatch: true, active: "HDMI-A-1" })
  assert.deepEqual([r.ok, r.nw, r.wc, r.moves], [false, "false", "1", ""])
  assert.match(r.err, /vista: .*dispatch failed/)
})

test("bar commands validate every value and fall back without a bar monitor", () => {
  // No known bar monitor: today's plain dispatch, or nothing where one is needed.
  assert.deepEqual(Array.from(Hypr.barFocusWorkspace(3, "")), Array.from(Hypr.focusWorkspace(3)))
  assert.deepEqual(Array.from(Hypr.barFocusWindow("0x1a", "")), Array.from(Hypr.focusWindow("0x1a")))
  assert.equal(Hypr.barFocusMonitor(""), null)
  assert.equal(Hypr.barFocusWorkspaceOn(4, ""), null)
  for (const bar of ['eDP-1" })', "desc:Panel", "bad name", "a\nb", "]]", null, undefined, 1]) {
    assert.deepEqual(Array.from(Hypr.barFocusWorkspace(3, bar)), Array.from(Hypr.focusWorkspace(3)), String(bar))
    assert.equal(Hypr.barFocusMonitor(bar), null, String(bar))
    assert.equal(Hypr.barFocusWorkspaceOn(4, bar), null, String(bar))
  }
  for (const id of [0, 51, "3) os.execute('x') --", "3\n", null]) {
    assert.equal(Hypr.barFocusWorkspace(id, "eDP-1"), null, String(id))
    assert.equal(Hypr.barFocusWorkspaceOn(id, "eDP-1"), null, String(id))
  }
  for (const a of ['0x1" }) os.execute("x") --', "address:0x1", "0x1\n", "", null])
    assert.equal(Hypr.barFocusWindow(a, "eDP-1"), null, String(a))
})

test("barAction maps every pillAction result", () => {
  assert.equal(Hypr.barAction("none", 3, "eDP-1"), null)
  assert.equal(Hypr.barAction("bogus", 3, "eDP-1"), null)
  assert.equal(Hypr.barAction(undefined, 3, "eDP-1"), null)
  assert.deepEqual(Array.from(Hypr.barAction("focusMonitor", 3, "eDP-1")), Array.from(Hypr.barFocusMonitor("eDP-1")))
  assert.deepEqual(Array.from(Hypr.barAction("focusWorkspace", 3, "eDP-1")), Array.from(Hypr.barFocusWorkspace(3, "eDP-1")))
  assert.deepEqual(Array.from(Hypr.barAction("focusWorkspaceOn", 4, "eDP-1")), Array.from(Hypr.barFocusWorkspaceOn(4, "eDP-1")))
  assert.deepEqual(Array.from(Hypr.barAction("focusWorkspace", 3, "")), Array.from(Hypr.focusWorkspace(3)))
})

test("a markup-shaped window title is plain text in the strip's tooltip", () => {
  const tip = Safe.plain('<img src="https://example.invalid/t">‮evil&amp;', 64)
  assert.ok(!/[<>&‪-‮⁦-⁩]/.test(tip), tip)
  assert.ok(tip.length <= 64)
})

test("workspaceRules builds one eval and skips invalid pins", () => {
  const argv = Array.from(Hypr.workspaceRules({ "1": "eDP-1", "2": 'bad"', "x": "eDP-1" }))
  assert.deepEqual(argv, ["/usr/bin/hyprctl", "eval", 'hl.workspace_rule({ workspace = "1", monitor = "eDP-1" })'])
  assert.equal(Hypr.workspaceRules({}), null)
})

test("monitor keys prefer the EDID description and fall back to the name", () => {
  const m = { name: "HDMI-A-1", lastIpcObject: { description: "Example 27in", model: "<b>X27</b>" } }
  assert.equal(Hypr.monitorKey(m), "desc:Example 27in")
  assert.deepEqual(Array.from(Hypr.monitorKeys(m)), ["desc:Example 27in", "HDMI-A-1"])
  assert.equal(Hypr.monitorKey({ name: "DP-2", lastIpcObject: {} }), "DP-2")
  assert.equal(Hypr.monitorLabel(m), "bX27/b")
  assert.equal(Hypr.monitorLabel({ name: "eDP-1" }), "Laptop")
})

test("bindStatus finds Vista's SUPER+TAB binds and any that compete", () => {
  const bind = (modmask, description, extra = {}) => ({ modmask, key: "TAB", submap: "", description, ...extra })
  const next = bind(64, "Vista: next workspace")
  const prev = bind(65, "Vista: previous workspace")
  const other = [bind(8, "Alt-Tab switcher"), bind(68, "Former workspace")]
  assert.equal(Hypr.bindStatus([...other, next, prev]), "ok")
  assert.equal(Hypr.bindStatus(other), "missing")
  assert.equal(Hypr.bindStatus([next]), "missing")
  assert.equal(Hypr.bindStatus([next, prev, bind(64, "Next workspace")]), "conflict")
  assert.equal(Hypr.bindStatus([next, prev, bind(65, "Previous workspace")]), "conflict")
  // A bind inside a submap only fires in that submap.
  assert.equal(Hypr.bindStatus([next, prev, bind(64, "x", { submap: "resize" })]), "ok")
  assert.equal(Hypr.bindStatus([next, prev, null, "x", 3]), "ok")
  // An unreadable reply never produces a warning.
  for (const bad of [null, undefined, {}, "[]", 5]) assert.equal(Hypr.bindStatus(bad), "ok", String(bad))
})

test("Omarchy commands use a plain OMARCHY_PATH or the packaged one", () => {
  assert.equal(Omarchy.bin("/usr/share/omarchy"), "/usr/share/omarchy/bin")
  assert.equal(Omarchy.bin("/home/me/src/omarchy"), "/home/me/src/omarchy/bin")
  for (const bad of ["", "relative/path", "/a/../b", "/a b", "/a;b", "/a\nb", null, undefined, 5])
    assert.equal(Omarchy.bin(bad), "/usr/share/omarchy/bin", String(bad))
})

test("the notification is critical, replaces only a real id, and opens the homepage on click", () => {
  const argv = Array.from(Omarchy.notify("", "missing", "0"))
  assert.equal(argv[0], "/usr/share/omarchy/bin/omarchy-notification-send")
  assert.deepEqual(argv.slice(1, 4), ["-p", "-r", "0"])
  assert.equal(argv[argv.indexOf("-u") + 1], "critical")
  assert.ok(argv.includes("Vista needs its keybindings"))
  assert.deepEqual(argv.slice(-3), ["--exec", "/usr/share/omarchy/bin/omarchy-launch-browser", "https://github.com/chyld/omarchy-vista"])
  assert.ok(Array.from(Omarchy.notify("", "conflict", "7")).includes("Vista needs Super+Tab to itself"))
  assert.equal(Omarchy.notify("", "missing", "42")[3], "42")
  for (const bad of ["-1", "01", "4 2", "x", "--exec", null, 12345678901])
    assert.equal(Omarchy.notify("", "missing", bad)[3], "0", String(bad))
})

test("one dismiss clears either headline", () => {
  assert.deepEqual(Array.from(Omarchy.dismiss("")), ["/usr/share/omarchy/bin/omarchy-notification-dismiss", "Vista needs"])
  for (const status of ["missing", "conflict"]) {
    const argv = Array.from(Omarchy.notify("", status, "0"))
    assert.ok(argv.some((a) => a.startsWith(Omarchy.HEADLINE_PREFIX + " ")), status)
  }
})
