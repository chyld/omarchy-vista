.pragma library
.import "Safe.js" as Safe

// Pure logic for the workspace strip in the bar (WorkspaceStrip.qml), and the
// workspace list the switcher shares with it. Every input is treated as
// untrusted: it comes from Hyprland or from shell.json.

var MAX_PILLS = 20
var MAX_ICONS = 5
var MAX_ICONS_VERTICAL = 3
var MAX_WALK = 64

function numeric(a, b) { return a - b }

// Always 1..count, plus every other valid workspace id in rawIds, ascending,
// without duplicates, at most MAX_PILLS. Only numbers and strings count as
// ids, so an array like [3] is not read as "3".
function workspaceIds(count, rawIds) {
  var n = Math.floor(Number(count))
  if (!isFinite(n) || n < 1) n = 1
  if (n > Safe.MAX_WORKSPACE) n = Safe.MAX_WORKSPACE
  var seen = Object.create(null)
  var ids = []
  for (var i = 1; i <= n; i++) { seen[i] = true; ids.push(i) }
  if (Array.isArray(rawIds)) {
    for (var j = 0; j < rawIds.length && j < 500; j++) {
      var raw = rawIds[j]
      if (typeof raw !== "number" && typeof raw !== "string") continue
      var id = Safe.workspaceId(raw)
      if (!id || seen[id]) continue
      seen[id] = true
      ids.push(Number(id))
    }
  }
  ids.sort(numeric)
  return ids.slice(0, MAX_PILLS)
}

// The ids scrolling may land on from a bar: those living on that bar's monitor
// and those that do not exist yet (they are created there). `owners` maps an
// existing workspace id to the output name of its monitor.
function scrollIds(ids, owners, monitorName) {
  var out = []
  if (!Array.isArray(ids)) return out
  var map = owners && typeof owners === "object" ? owners : {}
  for (var i = 0; i < ids.length; i++) {
    var key = String(ids[i])
    if (!Object.prototype.hasOwnProperty.call(map, key) || map[key] === monitorName) out.push(ids[i])
  }
  return out
}

// The id `steps` entries from currentId, holding at both ends. Positive steps
// go to the previous (lower) entry, as Util.wheelSteps reports a wheel moved
// up. -1 when there is nowhere to go from.
function scrollTarget(ids, currentId, steps) {
  if (!Array.isArray(ids) || ids.length === 0) return -1
  var s = Number(steps)
  if (!Number.isInteger(s) || s === 0) return -1
  var current = Number(currentId)
  var index = -1
  for (var i = 0; i < ids.length; i++) if (Number(ids[i]) === current) { index = i; break }
  if (index === -1) return -1
  var target = Math.max(0, Math.min(ids.length - 1, index - s))
  return Number(ids[target])
}

// The windows a pill shows: { shown: [{ address, toplevel }], hidden }.
// Ordered by address, which never changes while a window lives, so icons do
// not reshuffle on focus or a model refresh. Windows with an invalid address
// are skipped and not counted; past MAX_WALK they are counted unchecked.
function windowsFor(toplevels, maxIcons) {
  var list = toplevels && typeof toplevels.length === "number" ? toplevels : []
  var walk = Math.min(list.length, MAX_WALK)
  var valid = []
  for (var i = 0; i < walk; i++) {
    var t = list[i]
    var address = t ? Safe.windowAddress(t.address) : ""
    if (address) valid.push({ address: address, key: ("0000000000000000" + address.slice(2)).slice(-16), toplevel: t })
  }
  valid.sort(function(a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : 0 })
  var max = Math.max(0, Math.floor(Number(maxIcons)) || 0)
  var shown = []
  for (var j = 0; j < valid.length && j < max; j++) shown.push({ address: valid[j].address, toplevel: valid[j].toplevel })
  return { shown: shown, hidden: valid.length - shown.length + Math.max(0, list.length - MAX_WALK) }
}

// A pill's look, in precedence order: "here" (shown on this bar's monitor),
// "elsewhere" (shown on another monitor), "occupied", "empty".
function pillState(shownHere, shownElsewhere, occupied) {
  if (shownHere) return "here"
  if (shownElsewhere) return "elsewhere"
  return occupied ? "occupied" : "empty"
}
