// Unit tests for Strip.js, the logic behind the workspace strip in the bar and
// the workspace list it shares with the switcher. Run with: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = fileURLToPath(new URL("..", import.meta.url))

function load(file, globals = {}) {
  const src = readFileSync(root + file, "utf8").replace(/^\.(pragma|import) .*$/gm, "")
  const context = vm.createContext({ ...globals })
  vm.runInContext(src, context)
  return context
}

const Safe = load("Safe.js")
const Strip = load("Strip.js", { Safe })

// Arrays built inside the vm context fail deepEqual's prototype check.
const plain = (value) => JSON.parse(JSON.stringify(value))
const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i)

test("workspaceIds: always 1..count, plus existing ids, ascending", () => {
  assert.deepEqual(plain(Strip.workspaceIds(5, [])), [1, 2, 3, 4, 5])
  assert.deepEqual(plain(Strip.workspaceIds(5, [12, 2, 7])), [1, 2, 3, 4, 5, 7, 12])
  assert.deepEqual(plain(Strip.workspaceIds(3, ["12"])), [1, 2, 3, 12])
})

test("workspaceIds: ignores junk and collapses duplicates", () => {
  const junk = [null, undefined, NaN, Infinity, 0, -1, -99, 51, "1.5", "07", [12], { id: 12 }, true, "12", 12, "12"]
  assert.deepEqual(plain(Strip.workspaceIds(5, junk)), [1, 2, 3, 4, 5, 12])
  assert.deepEqual(plain(Strip.workspaceIds(5, "12")), [1, 2, 3, 4, 5])
  assert.deepEqual(plain(Strip.workspaceIds(5, null)), [1, 2, 3, 4, 5])
  assert.deepEqual(plain(Strip.workspaceIds(5, [3, "3"])), [1, 2, 3, 4, 5])
})

test("workspaceIds: count is clamped and the list capped", () => {
  assert.deepEqual(plain(Strip.workspaceIds(0, [])), [1])
  assert.deepEqual(plain(Strip.workspaceIds("x", [])), [1])
  assert.deepEqual(plain(Strip.workspaceIds(999, [])), range(1, Strip.MAX_PILLS))
  // Existing workspaces take the room first; the always-shown ones fill the rest.
  assert.deepEqual(plain(Strip.workspaceIds(10, range(30, 45))), [1, 2, 3, 4, 30, ...range(31, 45)].sort((a, b) => a - b))
  assert.deepEqual(plain(Strip.workspaceIds(5, [3, 40])), [1, 2, 3, 4, 5, 40])
})

test("workspaceIds: an existing workspace is never capped away", () => {
  // Workspaces 1..21 all exist: 21 (say, the one a monitor shows) stays.
  assert.deepEqual(plain(Strip.workspaceIds(5, range(1, 21))), range(1, 21))
  assert.deepEqual(plain(Strip.workspaceIds(50, [...range(1, 20), 50])), [...range(1, 20), 50])
  // Every existing one stays even past the cap, so the switcher can reach it.
  assert.equal(Strip.workspaceIds(3, range(1, 50)).length, 50)
})

test("scrollIds: keeps this monitor's and not-yet-existing workspaces", () => {
  const owners = { 1: "eDP-1", 2: "HDMI-A-1", 5: "HDMI-A-1" }
  assert.deepEqual(plain(Strip.scrollIds([1, 2, 3, 4, 5], owners, "eDP-1")), [1, 3, 4])
  assert.deepEqual(plain(Strip.scrollIds([1, 2, 3, 4, 5], owners, "HDMI-A-1")), [2, 3, 4, 5])
  assert.deepEqual(plain(Strip.scrollIds(null, owners, "eDP-1")), [])
  assert.deepEqual(plain(Strip.scrollIds([1, 2], null, "eDP-1")), [1, 2])
  // Inherited keys are not owners.
  assert.deepEqual(plain(Strip.scrollIds([1], Object.create({ 1: "HDMI-A-1" }), "eDP-1")), [1])
})

test("scrollTarget: positive steps go to the previous workspace, holding at the ends", () => {
  const ids = [1, 3, 4, 7]
  assert.equal(Strip.scrollTarget(ids, 3, 1), 1)
  assert.equal(Strip.scrollTarget(ids, 3, -1), 4)
  assert.equal(Strip.scrollTarget(ids, 1, 1), 1)
  assert.equal(Strip.scrollTarget(ids, 7, -1), 7)
  assert.equal(Strip.scrollTarget(ids, 4, 9), 1)
  assert.equal(Strip.scrollTarget(ids, 3, -9), 7)
  assert.equal(Strip.scrollTarget(ids, "4", 1), 3)
  assert.equal(Strip.scrollTarget(["1", "3"], 3, 1), 1)
})

test("scrollTarget: nowhere to go from gives -1", () => {
  assert.equal(Strip.scrollTarget([1, 2], 9, 1), -1)
  assert.equal(Strip.scrollTarget([], 1, 1), -1)
  assert.equal(Strip.scrollTarget(null, 1, 1), -1)
  for (const steps of [0, NaN, 1.5, "x", undefined])
    assert.equal(Strip.scrollTarget([1, 2, 3], 2, steps), -1, String(steps))
})

const win = (address, extra = {}) => ({ address, ...extra })

test("windowsFor: ordered by address, not by input order", () => {
  const out = Strip.windowsFor([win("1f0"), win("0x00a"), win("2"), win("100")], 5)
  assert.deepEqual(plain(out.shown.map((w) => w.address)), ["0x2", "0xa", "0x100", "0x1f0"])
  assert.equal(out.hidden, 0)
  assert.equal(out.shown[0].toplevel.address, "2")
})

test("windowsFor: caps icons and counts the rest", () => {
  const list = range(1, 8).map((n) => win(n.toString(16)))
  assert.equal(Strip.windowsFor(list, Strip.MAX_ICONS).shown.length, 5)
  assert.equal(Strip.windowsFor(list, Strip.MAX_ICONS).hidden, 3)
  assert.equal(Strip.windowsFor(list, Strip.MAX_ICONS_VERTICAL).hidden, 5)
  assert.equal(Strip.windowsFor(list, 0).shown.length, 0)
  assert.equal(Strip.windowsFor(list, 0).hidden, 8)
})

test("windowsFor: skips invalid addresses without counting them", () => {
  const out = Strip.windowsFor([win("a"), win("address:0xb"), win("x"), null, {}, win(12), win("c")], 5)
  assert.deepEqual(plain(out.shown.map((w) => w.address)), ["0xa", "0xc"])
  assert.equal(out.hidden, 0)
})

test("windowsFor: past the walk bound, windows are counted unchecked", () => {
  const list = range(1, 70).map((n) => win(n.toString(16)))
  const out = Strip.windowsFor(list, 5)
  assert.equal(out.shown.length, 5)
  assert.equal(out.hidden, 65)
})

test("windowsFor: tolerates bare toplevels and bad input", () => {
  assert.equal(Strip.windowsFor([win("a")], 5).shown.length, 1)
  assert.deepEqual(plain(Strip.windowsFor(null, 5)), { shown: [], hidden: 0 })
  assert.deepEqual(plain(Strip.windowsFor("abc", 5)), { shown: [], hidden: 0 })
})

test("pillState: shown here > shown elsewhere > occupied > empty", () => {
  for (const elsewhere of [false, true]) for (const occupied of [false, true])
    assert.equal(Strip.pillState(true, elsewhere, occupied), "here")
  assert.equal(Strip.pillState(false, true, false), "elsewhere")
  assert.equal(Strip.pillState(false, true, true), "elsewhere")
  assert.equal(Strip.pillState(false, false, true), "occupied")
  assert.equal(Strip.pillState(false, false, false), "empty")
})

test("fitIcons: shows as many icons as fit the budget, down to none", () => {
  const sizes = { fixed: 30, pill: 30, icon: 20, more: 15 }
  const counts = [2, 6, 0, 3]
  // Full: 30 + 4*30 + (2+5+0+3)*20 + 15 (the 6-window pill's "+1") = 365
  assert.equal(Strip.fitIcons(counts, 5, sizes, 365), 5)
  assert.equal(Strip.fitIcons(counts, 5, sizes, 364), 4)
  // Three icons: 30 + 120 + (2+3+0+3)*20 + 15 = 325
  assert.equal(Strip.fitIcons(counts, 5, sizes, 325), 3)
  assert.equal(Strip.fitIcons(counts, 5, sizes, 100), 0)
  assert.equal(Strip.fitIcons(counts, 3, sizes, 10000), 3)
})

test("fitIcons: without a budget or counts it keeps the cap", () => {
  const sizes = { fixed: 0, pill: 10, icon: 10, more: 10 }
  assert.equal(Strip.fitIcons([9], 5, sizes, 0), 5)
  assert.equal(Strip.fitIcons(null, 5, sizes, 100), 5)
  assert.equal(Strip.fitIcons([9], 5, null, 100), 5)
  assert.equal(Strip.fitIcons(["x", -3, NaN], 5, sizes, 30), 5)
  assert.equal(Strip.fitIcons([9], "x", sizes, 100), 0)
})

test("sameList compares ids in order, numbers and strings alike", () => {
  assert.equal(Strip.sameList([1, 2, 5], [1, 2, 5]), true)
  assert.equal(Strip.sameList([1, 2, 5], ["1", "2", "5"]), true)
  assert.equal(Strip.sameList([1, 2, 5], [1, 5, 2]), false)
  assert.equal(Strip.sameList([1, 2], [1, 2, 3]), false)
  assert.equal(Strip.sameList(null, []), false)
})

test("windowsKey changes only when the shown windows or the hidden count do", () => {
  const a = Strip.windowsFor([win("b"), win("a")], 5)
  const b = Strip.windowsFor([win("a"), win("b")], 5)
  assert.equal(Strip.windowsKey(a), Strip.windowsKey(b))
  assert.notEqual(Strip.windowsKey(a), Strip.windowsKey(Strip.windowsFor([win("a")], 5)))
  assert.notEqual(Strip.windowsKey(Strip.windowsFor([win("a"), win("b")], 1)), Strip.windowsKey(Strip.windowsFor([win("a")], 1)))
  assert.equal(Strip.windowsKey(null), "")
})

test("pillAction: what a click from a bar does", () => {
  // Already shown on this bar's monitor: only focus the monitor, if needed.
  assert.equal(Strip.pillAction(3, { activeId: 3, focused: true }, true), "none")
  assert.equal(Strip.pillAction(3, { activeId: 3, focused: false }, true), "focusMonitor")
  assert.equal(Strip.pillAction("3", { activeId: 3, focused: false }, true), "focusMonitor")
  // Exists elsewhere (shown or not): show it where it lives.
  assert.equal(Strip.pillAction(5, { activeId: 3, focused: false }, true), "focusWorkspace")
  // Doesn't exist: create it on this bar's monitor.
  assert.equal(Strip.pillAction(4, { activeId: 3, focused: false }, false), "focusWorkspaceOn")
  assert.equal(Strip.pillAction(4, { activeId: 3, focused: true }, false), "focusWorkspaceOn")
  // No monitor known: plain focus.
  assert.equal(Strip.pillAction(4, null, false), "focusWorkspace")
  assert.equal(Strip.pillAction(4, null, true), "focusWorkspace")
})
