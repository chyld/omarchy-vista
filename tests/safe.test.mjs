// Unit tests for Safe.js and Hypr.js, the code every untrusted value passes
// through. Run with: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
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
