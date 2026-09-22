import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Safe.js" as Safe
import "Hypr.js" as Hypr

// Keeps Hyprland's workspace placement in line with the pins setting.
//
// A pin becomes a runtime workspace rule, which replaces the config's rule for
// that workspace; nothing is written to any Hyprland file. Hyprland drops
// runtime rules on a config reload, so they are applied again after every
// reload and when a monitor connects. A rule cannot be taken back, only
// replaced, so unpinning reloads the config (restoring the workspace's own
// rule) and then moves the workspace to the monitor that rule names.
Item {
  id: pins

  // Workspace id -> monitor key, already validated (Safe.pins).
  property var desired: Object.create(null)
  // Set once the first settings have arrived; nothing happens before that.
  property bool ready: false

  property var applied: Object.create(null)
  property var unpinned: []

  onReadyChanged: if (ready) apply()
  // Coalesce bursts of changes (several clicks in the settings popup) into
  // one sync, so they never trigger overlapping reloads.
  onDesiredChanged: if (ready) syncTimer.restart()

  Timer {
    id: syncTimer
    interval: 250
    onTriggered: if (JSON.stringify(pins.desired) !== JSON.stringify(pins.applied)) pins.sync()
  }

  function run(argv) {
    if (argv) Quickshell.execDetached(argv)
  }

  // The monitors a pin may name right now: a closed allowlist of keys.
  function connected() {
    var keys = Object.create(null)
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      var list = Hypr.monitorKeys(values[i])
      for (var k = 0; k < list.length; k++) keys[list[k]] = true
    }
    return keys
  }

  function sync() {
    var removed = []
    for (var id in pins.applied) if (!pins.desired[id]) removed.push(id)
    if (removed.length > 0) {
      pins.unpinned = removed
      pins.run(Hypr.reload())   // apply() and sendHome() follow the reload
      return
    }
    pins.apply()
  }

  function apply() {
    var live = connected()
    var current = Object.create(null)
    // A pin to a monitor that is not connected waits for it to appear.
    for (var id in pins.desired) if (live[pins.desired[id]]) current[id] = pins.desired[id]
    pins.applied = current
    pins.run(Hypr.workspaceRules(current))

    // Move pinned workspaces that already exist onto their monitor.
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      var wsId = Safe.workspaceId(ws.id)
      var target = wsId ? current[wsId] : undefined
      if (!target || !ws.monitor) continue
      if (Hypr.monitorKeys(ws.monitor).indexOf(target) !== -1) continue
      pins.run(Hypr.moveWorkspace(wsId, target))
    }
  }

  // After an unpin: move each unpinned workspace to the monitor its own
  // config rule names, if that monitor is connected.
  function sendHome(json) {
    var ids = pins.unpinned
    pins.unpinned = []
    var rules
    try { rules = JSON.parse(json) } catch (e) { return }
    if (!Array.isArray(rules) || rules.length > 500) return
    var live = connected()
    var values = Hyprland.workspaces.values
    for (var i = 0; i < ids.length; i++) {
      var home = ""
      for (var r = 0; r < rules.length; r++) {
        var rule = rules[r]
        if (rule && rule.workspaceString === ids[i] && typeof rule.monitor === "string") home = rule.monitor
      }
      if (!home || !live[home]) continue
      for (var w = 0; w < values.length; w++) {
        if (Safe.workspaceId(values[w].id) === ids[i]) pins.run(Hypr.moveWorkspace(ids[i], home))
      }
    }
  }

  // The rules list is read in chunks under a 64 KiB budget with a 3 s deadline.
  Process {
    id: rulesQuery
    property string buf: ""
    property bool overflow: false
    command: Hypr.listWorkspaceRules()
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (rulesQuery.overflow) return
        rulesQuery.buf += chunk
        if (rulesQuery.buf.length > 65536) { rulesQuery.overflow = true; rulesQuery.buf = ""; rulesQuery.signal(15) }
      }
    }
    onStarted: { buf = ""; overflow = false; rulesDeadline.restart() }
    onExited: function(code) {
      rulesDeadline.stop()
      var json = overflow || code !== 0 ? "" : buf
      buf = ""
      pins.sendHome(json)
    }
  }

  Timer { id: rulesDeadline; interval: 3000; onTriggered: rulesQuery.signal(9) }

  // Stop an in-flight query when the plugin unloads.
  Component.onDestruction: if (rulesQuery.running) rulesQuery.signal(9)

  // Monitors report their details a moment after they connect.
  Timer { id: monitorSettle; interval: 500; onTriggered: pins.apply() }

  Connections {
    target: Hyprland
    enabled: pins.ready
    function onRawEvent(event) {
      if (event.name === "configreloaded") {
        pins.apply()
        if (pins.unpinned.length > 0 && !rulesQuery.running) rulesQuery.running = true
      } else if (event.name === "monitoradded" || event.name === "monitoraddedv2") {
        Hyprland.refreshMonitors()
        monitorSettle.restart()
      }
    }
  }
}
