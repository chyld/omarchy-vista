import QtQuick
import Quickshell
import Quickshell.Hyprland
import "Defaults.js" as Defaults
import "Safe.js" as Safe
import "Hypr.js" as Hypr

// Vista: alt-tab for workspaces.
//
// Hold SUPER and tap TAB to cycle workspaces in numeric order; release SUPER
// to switch. This service owns the state and actions; Switcher.qml draws them.
//
//   Service.qml           settings, switcher state, input, open/commit/close
//   Switcher.qml          the overlay window (view only)
//   WorkspacePreview.qml  one workspace drawn to scale
//   SuperWatch.qml        asks Hyprland whether SUPER is still held
//   PinManager.qml        monitor pins as runtime Hyprland workspace rules
//   AppIcons.qml          app icons per workspace, bounded cache
//   Hypr.js               every hyprctl command Vista runs
//   Safe.js               validation of everything that is not a literal
//   Settings.qml          the bar icon and its settings popup
//
// The keybinding sends a Hyprland global shortcut (see bindings.lua), so a
// press reaches this long-running service without spawning a process.
Item {
  id: vista

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "chyld.vista"
  readonly property string wallpaperPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"

  // ------------------------------------------------------------ settings

  // Settings live on this plugin's bar entry in shell.json, saved by the host
  // when the settings popup changes them; Vista never reads the file. The bar
  // icon hands its current settings straight to this service. Without the
  // icon, the host's copy of the bar config is used.
  property var pushedSettings: null

  readonly property var settings: {
    if (vista.pushedSettings && typeof vista.pushedSettings === "object") return vista.pushedSettings
    var cfg = vista.shell && vista.shell.barConfig ? vista.shell.barConfig : null
    var layout = cfg && cfg.layout ? cfg.layout : null
    if (!layout) return ({})
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length && i < 200; i++) {
        var entry = list[i]
        if (entry && typeof entry === "object" && entry.id === vista.pluginId) return entry
      }
    }
    return ({})
  }

  function setting(key) {
    var v = vista.settings[key]
    return (v === undefined || v === null) ? Defaults.values[key] : v
  }
  function settingNumber(key, min, max) {
    var n = Number(setting(key))
    return isFinite(n) ? Math.max(min, Math.min(max, n)) : Defaults.values[key]
  }
  function settingBool(key) {
    var v = setting(key)
    return v === true || v === "true"
  }

  readonly property int workspaceCount: settingNumber("workspaces", 1, Safe.MAX_WORKSPACE)
  readonly property real previewSize: settingNumber("previewSize", 0.2, 0.9)
  readonly property int thumbnailWidth: settingNumber("thumbnailWidth", 60, 600)
  readonly property int gap: settingNumber("gap", 0, 200)
  readonly property bool showIcons: settingBool("showIcons")
  readonly property bool showWallpaper: settingBool("showWallpaper")
  readonly property int animationDuration: settingBool("animations") ? 150 : 0

  // ------------------------------------------------------------ modules

  PinManager {
    id: pins
    desired: Safe.pins(vista.settings.pins)
  }

  // Pins wait for the host to hand over the plugin's settings.
  onShellChanged: if (vista.shell) Qt.callLater(function() { pins.ready = true })

  AppIcons { id: icons }

  SuperWatch {
    id: superWatch
    onReleased: vista.commit()
  }

  Switcher {
    id: switcher
    vista: vista
    icons: icons
  }

  // ------------------------------------------------------------ switcher state

  property bool opened: false         // logical state (drives the fade)
  property bool presented: false      // window mapped (stays true through fade-out)
  property bool revealed: false       // content shown (skipped entirely on a quick tap)
  property var entries: []            // [{ id, workspace }] in numeric order
  property int selectedIndex: 0
  property var targetMonitor: null
  property real lastStepAt: 0

  readonly property var selectedEntry: selectedIndex >= 0 && selectedIndex < entries.length ? entries[selectedIndex] : null

  // Always 1..workspaceCount, plus any other normal workspace that exists, up
  // to Safe.MAX_WORKSPACE.
  function buildEntries() {
    var values = Hyprland.workspaces.values
    var existing = Object.create(null)
    var ids = []
    for (var n = 1; n <= vista.workspaceCount; n++) ids.push(n)
    for (var i = 0; i < values.length; i++) {
      var id = Safe.workspaceId(values[i].id)
      if (!id) continue
      existing[id] = values[i]
      if (Number(id) > vista.workspaceCount) ids.push(Number(id))
    }
    ids.sort(function(a, b) { return a - b })
    var list = []
    for (var k = 0; k < ids.length; k++) list.push({ id: ids[k], workspace: existing[String(ids[k])] || null })
    vista.entries = list
  }

  function indexOfWorkspace(id) {
    for (var i = 0; i < vista.entries.length; i++) if (vista.entries[i].id === id) return i
    return -1
  }

  // ------------------------------------------------------------ input

  GlobalShortcut {
    appid: "chyld-vista"
    name: "next"
    onPressed: vista.step(1)
  }

  GlobalShortcut {
    appid: "chyld-vista"
    name: "prev"
    onPressed: vista.step(-1)
  }

  // One Tab press can arrive twice: as the compositor bind and as a key event
  // on the focused overlay. Only the first counts.
  function step(direction) {
    var now = Date.now()
    if (now - vista.lastStepAt < 20) return
    vista.lastStepAt = now
    if (!vista.opened) vista.open(direction)
    else vista.cycle(direction)
  }

  // Tab cycling wraps; arrow keys and the wheel stop at the ends.
  function cycle(direction) {
    var n = vista.entries.length
    if (n > 0) vista.selectedIndex = ((vista.selectedIndex + direction) % n + n) % n
  }

  function move(delta) {
    var n = vista.entries.length
    if (n > 0) vista.selectedIndex = Math.max(0, Math.min(n - 1, vista.selectedIndex + delta))
  }

  function select(index) {
    if (index >= 0 && index < vista.entries.length) vista.selectedIndex = index
  }

  function jump(workspaceId) {
    var index = vista.indexOfWorkspace(workspaceId)
    if (index !== -1) { vista.selectedIndex = index; vista.commit() }
  }

  // ------------------------------------------------------------ lifecycle

  function open(direction) {
    closeTimer.stop()
    if (vista.pendingSwitch !== -1) vista.finishSwitch()
    settleCheck.stop()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    vista.targetMonitor = Hyprland.focusedMonitor
    vista.buildEntries()

    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    var current = vista.indexOfWorkspace(focusedId)
    // From a special or unlisted workspace, "next" starts at the first card.
    vista.selectedIndex = current !== -1 ? current : (direction > 0 ? vista.entries.length - 1 : 0)
    vista.cycle(direction)

    vista.revealed = false
    vista.presented = true
    vista.opened = true
    revealTimer.restart()
    superWatch.start()
    Qt.callLater(switcher.focusKeys)
  }

  function commit() {
    if (!vista.opened) return
    var entry = vista.selectedEntry
    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    var argv = entry && entry.id !== focusedId ? Hypr.focusWorkspace(entry.id) : null
    if (!argv) { vista.close(true); return }

    // Switch while the overlay is still mapped (hidden), and unmap only once
    // Hyprland reports the new workspace. Unmapping first races the switch:
    // Hyprland refocuses the last focused window when the overlay goes, and
    // that can pull the old workspace back.
    vista.opened = false
    revealTimer.stop()
    superWatch.stop()
    vista.pendingSwitch = entry.id
    vista.pendingArgv = argv
    Quickshell.execDetached(argv)
    switchDeadline.restart()
  }

  // Workspace id being switched to while the hidden overlay waits to unmap.
  property int pendingSwitch: -1
  property var pendingArgv: null

  // Unmap the overlay, then make sure the switch held. Closing the overlay
  // hands keyboard focus back to Hyprland, which gives it to the window under
  // the mouse; when that is on another monitor it takes focus away from the
  // workspace we just switched to, so the switch is repeated once without the
  // overlay in the way.
  function finishSwitch() {
    switchDeadline.stop()
    settleCheck.target = vista.pendingSwitch
    settleCheck.argv = vista.pendingArgv
    vista.pendingSwitch = -1
    vista.pendingArgv = null
    vista.finishClose()
    if (settleCheck.argv) settleCheck.restart()
  }

  Connections {
    target: Hyprland
    enabled: vista.pendingSwitch !== -1
    function onFocusedWorkspaceChanged() {
      if (Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === vista.pendingSwitch) vista.finishSwitch()
    }
  }

  // Hyprland normally switches within a frame or two; unmap regardless after
  // 300 ms so the overlay can never hang around.
  Timer {
    id: switchDeadline
    interval: 300
    onTriggered: vista.finishSwitch()
  }

  Timer {
    id: settleCheck
    property int target: -1
    property var argv: null
    interval: 80
    onTriggered: {
      var focused = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
      if (argv && focused !== target) Quickshell.execDetached(argv)
      argv = null
      target = -1
    }
  }

  function close(immediate) {
    if (!vista.opened) return
    vista.opened = false
    revealTimer.stop()
    superWatch.stop()
    // Fade out only when cancelling a switcher that was showing.
    if (!immediate && vista.revealed && vista.animationDuration > 0) closeTimer.restart()
    else vista.finishClose()
  }

  function finishClose() {
    vista.presented = false
    vista.revealed = false
    vista.entries = []
  }

  // Delay showing the switcher so a quick SUPER+TAB tap switches without a flash.
  Timer {
    id: revealTimer
    interval: 120
    onTriggered: vista.revealed = true
  }

  Timer {
    id: closeTimer
    interval: vista.animationDuration + 20
    onTriggered: if (!vista.opened) vista.finishClose()
  }

  // Keep window geometry fresh while the switcher shows: Hyprland only updates
  // lastIpcObject on refresh.
  Connections {
    target: Hyprland
    enabled: vista.presented
    function onRawEvent(event) {
      var n = event.name
      if (n === "movewindow" || n === "movewindowv2" || n === "changefloatingmode" ||
          n === "fullscreen" || n === "openwindow" || n === "closewindow" ||
          n === "windowtitle" || n === "windowtitlev2") {
        Hyprland.refreshToplevels()
      }
    }
  }
}
