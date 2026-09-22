import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Defaults.js" as Defaults
import "Safe.js" as Safe

// Vista: alt-tab for workspaces.
//
// Hold SUPER and tap TAB to cycle workspaces in numeric order; release SUPER
// to switch. The selected workspace fills a large live preview, with its
// number and app icons beneath and a filmstrip of every workspace below. The keybinding sends a
// Hyprland global shortcut (see bindings.lua), so each press goes straight to
// this long-running service with no process spawned.
//
// Releasing SUPER is seen two ways: as a key event on the overlay (which takes
// exclusive keyboard focus while open), and by asking the compositor whether
// SUPER is still down. The second covers a tap released before focus arrives,
// and any release the overlay never receives.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "chyld.vista"
  readonly property string backgroundPath: home + "/.local/state/omarchy/current/background"

  property bool opened: false         // logical state (drives the fade)
  property bool presented: false      // window mapped (stays true through fade-out)
  property bool revealed: false       // content shown (skipped entirely on a quick tap)
  property var entries: []
  property int selectedIndex: 0
  property real openedAt: 0
  property real lastStepAt: 0
  property var targetMonitor: null
  property real lastPointerX: -1
  property real lastPointerY: -1

  // ------------------------------------------------------------ settings

  readonly property string hyprctl: "/usr/bin/hyprctl"

  // Settings live on this plugin's bar entry in shell.json, where the settings
  // panel (Settings.qml) saves them through the host; the switcher never reads
  // shell.json itself. The bar icon hands its current settings straight to this
  // service (`pushedSettings`). Without the icon, the host's copy of the bar
  // config is used, which it refreshes one change behind.
  property var pushedSettings: null

  readonly property var settings: {
    if (root.pushedSettings && typeof root.pushedSettings === "object") return root.pushedSettings
    var cfg = root.shell && root.shell.barConfig ? root.shell.barConfig : null
    var layout = cfg && cfg.layout ? cfg.layout : null
    if (!layout) return ({})
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length && i < 200; i++) {
        var entry = list[i]
        if (entry && typeof entry === "object" && entry.id === root.pluginId) return entry
      }
    }
    return ({})
  }

  function setting(key) {
    var v = root.settings[key]
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
  readonly property int gapSetting: settingNumber("gap", 0, 200)
  readonly property bool showIcons: settingBool("showIcons")
  readonly property bool showWallpaper: settingBool("showWallpaper")
  readonly property int animationDuration: settingBool("animations") ? 150 : 0
  readonly property var pins: Safe.pins(root.settings.pins)

  // ------------------------------------------------------------ monitor pins

  // Pins become Hyprland workspace rules at runtime, which replace the config's
  // rule for that workspace. Hyprland drops them on a config reload, so they
  // are applied again whenever the config reloads or a monitor connects.
  // Nothing is written to any Hyprland file.
  property var appliedPins: Object.create(null)
  property var unpinned: []          // workspaces to send home after the reload
  property bool pinsReady: false

  onShellChanged: if (root.shell && !root.pinsReady) { root.pinsReady = true; Qt.callLater(root.applyPins) }

  // A settings save hands back a fresh pins object; only act when the pins
  // themselves changed.
  onPinsChanged: if (root.pinsReady && JSON.stringify(root.pins) !== JSON.stringify(root.appliedPins)) root.syncPins()

  // The closed set of monitor keys a pin may name: the connected monitors.
  function connectedMonitors() {
    var keys = Object.create(null)
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject || {}
      var byName = Safe.monitorKey(String(values[i].name || ""))
      var byDesc = ipc.description ? Safe.monitorKey("desc:" + ipc.description) : ""
      if (byName) keys[byName] = true
      if (byDesc) keys[byDesc] = true
    }
    return keys
  }

  function syncPins() {
    var removed = []
    for (var id in root.appliedPins) if (!root.pins[id]) removed.push(id)
    if (removed.length > 0) {
      // A rule cannot be taken back, only replaced: reload the config to
      // restore the workspace's own rule. applyPins() runs after the reload,
      // then the unpinned workspaces move back to where the config puts them.
      root.unpinned = removed
      Quickshell.execDetached([root.hyprctl, "reload"])
      return
    }
    root.applyPins()
  }

  function moveWorkspace(id, monitor) {
    Quickshell.execDetached([root.hyprctl, "dispatch",
      "hl.dsp.workspace.move({ workspace = " + Safe.luaQuote(id) + ", monitor = " + Safe.luaQuote(monitor) + " })"])
  }

  function applyPins() {
    var connected = root.connectedMonitors()
    var lua = []
    var current = Object.create(null)
    for (var id in root.pins) {
      var target = root.pins[id]
      // Pins to a monitor that is not connected wait for it to appear.
      if (!connected[target]) continue
      current[id] = target
      lua.push("hl.workspace_rule({ workspace = " + Safe.luaQuote(id) + ", monitor = " + Safe.luaQuote(target) + " })")
    }
    root.appliedPins = current
    if (lua.length === 0) return
    Quickshell.execDetached([root.hyprctl, "eval", lua.join("\n")])

    // Move pinned workspaces that already exist onto their monitor.
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      var wsId = Safe.workspaceId(ws.id)
      var pin = wsId ? current[wsId] : undefined
      if (!pin || !ws.monitor) continue
      var mon = ws.monitor.lastIpcObject || {}
      if (pin === "desc:" + mon.description || pin === ws.monitor.name) continue
      root.moveWorkspace(wsId, pin)
    }
  }

  // After an unpin, send each unpinned workspace to the monitor its own
  // config rule names, if that monitor is connected.
  function sendUnpinnedHome(json) {
    var ids = root.unpinned
    root.unpinned = []
    var rules = []
    try { rules = JSON.parse(json) } catch (e) { return }
    if (!Array.isArray(rules) || rules.length > 500) return
    var connected = root.connectedMonitors()
    var values = Hyprland.workspaces.values
    for (var i = 0; i < ids.length; i++) {
      var home = ""
      for (var r = 0; r < rules.length; r++) {
        var rule = rules[r]
        if (rule && rule.workspaceString === ids[i] && typeof rule.monitor === "string") home = rule.monitor
      }
      if (!home || !connected[home]) continue
      for (var w = 0; w < values.length; w++) {
        if (Safe.workspaceId(values[w].id) === ids[i]) root.moveWorkspace(ids[i], home)
      }
    }
  }

  // hyprctl replies are read in chunks under a byte budget, and each call has
  // a deadline; nothing is collected whole.
  Process {
    id: rulesProc
    property string buf: ""
    property bool overflow: false
    command: [root.hyprctl, "workspacerules", "-j"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (rulesProc.overflow) return
        rulesProc.buf += chunk
        if (rulesProc.buf.length > 65536) { rulesProc.overflow = true; rulesProc.buf = ""; rulesProc.signal(15) }
      }
    }
    onStarted: { buf = ""; overflow = false; rulesDeadline.restart() }
    onExited: function(code) {
      rulesDeadline.stop()
      var json = overflow || code !== 0 ? "" : buf
      buf = ""
      root.sendUnpinnedHome(json)
    }
  }

  Timer { id: rulesDeadline; interval: 3000; onTriggered: rulesProc.signal(9) }

  // Re-apply after a reload, and when a monitor a pin waits for connects.
  Timer { id: monitorSettle; interval: 500; onTriggered: root.applyPins() }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.pinsReady) return
      if (event.name === "configreloaded") {
        root.applyPins()
        if (root.unpinned.length > 0 && !rulesProc.running) rulesProc.running = true
      } else if (event.name === "monitoradded" || event.name === "monitoraddedv2") {
        Hyprland.refreshMonitors()
        monitorSettle.restart()
      }
    }
  }

  // ------------------------------------------------------------ theme

  // Borders and text share the image-picker tokens, so themes that style the
  // theme and background pickers style the switcher too.
  // A near-opaque wash of the theme background: the switcher replaces the
  // screen while it is open instead of floating over a busy page.
  readonly property color scrim: Util.alpha(Color.background, 0.96)
  readonly property color foreground: Color.imagePicker.text
  readonly property color selectedBorder: Color.imagePicker.selectedBorder
  readonly property color unselectedBorder: Color.imagePicker.unselectedBorder
  readonly property string fontFamily: Style.font.menuFamily

  // ------------------------------------------------------------ geometry

  readonly property real monitorWidth: targetMonitor ? targetMonitor.width / Math.max(0.1, targetMonitor.scale) : 1440
  readonly property real monitorHeight: targetMonitor ? targetMonitor.height / Math.max(0.1, targetMonitor.scale) : 900
  readonly property real aspect: monitorHeight / Math.max(1, monitorWidth)
  // The large preview takes previewSize of the screen width, but never so much
  // height that the number row and filmstrip no longer fit beneath it.
  readonly property int heroWidth: Math.round(Math.min(monitorWidth * previewSize, monitorHeight * 0.55 / aspect))
  readonly property int heroHeight: Math.round(heroWidth * aspect)
  readonly property int heroNumberSize: Math.max(Style.font.body * 4, Math.round(heroHeight * 0.16))
  readonly property int heroIconSize: Style.space(28)
  readonly property int thumbGap: Style.space(gapSetting)
  // Thumbnails shrink so the filmstrip always fits on screen.
  readonly property int thumbWidth: {
    var n = Math.max(1, entries.length)
    var fit = Math.floor((monitorWidth - Style.space(128) - (n - 1) * thumbGap) / n)
    return Math.max(Style.space(48), Math.min(Style.space(thumbnailWidth), fit))
  }
  readonly property int thumbHeight: Math.round(thumbWidth * aspect)
  readonly property int thumbIconSize: Style.space(16)
  readonly property int borderWidth: Math.max(2, Style.space(2))
  readonly property var selectedEntry: selectedIndex >= 0 && selectedIndex < entries.length ? entries[selectedIndex] : null

  // ------------------------------------------------------------ app icons

  // Looked up inside bindings, so it is mutated in place and never reassigned:
  // a notifying property here would be a binding loop.
  readonly property var iconCache: ({ map: Object.create(null), size: 0 })

  // Window classes are set by the application, so only a plain name is used.
  function appClass(toplevel) {
    var ipc = toplevel.lastIpcObject || {}
    if (ipc.class) return Safe.appClass(ipc.class)
    return toplevel.wayland && toplevel.wayland.appId ? Safe.appClass(toplevel.wayland.appId) : ""
  }

  // A desktop entry's Icon= is a theme name, or an absolute path, which is
  // accepted only inside the system and user icon and application folders.
  function iconSource(icon) {
    var s = String(icon || "")
    if (s.length === 0 || s.length > 512 || /[\u0000-\u001f]/.test(s)) return ""
    if (s.charAt(0) !== "/") return /^[A-Za-z0-9._+-]{1,128}$/.test(s) ? Quickshell.iconPath(s, true) : ""
    if (s.indexOf("/../") !== -1 || s.indexOf("/./") !== -1 || !/\.(png|svg)$/i.test(s)) return ""
    var roots = ["/usr/share/icons/", "/usr/share/pixmaps/",
                 root.home + "/.local/share/icons/", root.home + "/.local/share/applications/icons/"]
    for (var i = 0; i < roots.length; i++) if (s.indexOf(roots[i]) === 0) return Quickshell.iconPath(s, true)
    return ""
  }

  // Desktop entry by id, then by StartupWMClass, then the icon theme directly.
  function iconFor(cls) {
    if (!cls) return ""
    var cache = root.iconCache
    if (cache.map[cls] !== undefined) return cache.map[cls]
    // Bounded for the life of the shell: start over rather than grow.
    if (cache.size >= 200) { cache.map = Object.create(null); cache.size = 0 }
    var lower = cls.toLowerCase()
    var path = ""
    var ids = [cls, lower, lower.split(".").pop()]
    for (var i = 0; i < ids.length && !path; i++) {
      var entry = DesktopEntries.byId(ids[i])
      if (entry && entry.icon) path = root.iconSource(entry.icon)
    }
    var apps = DesktopEntries.applications.values
    for (var j = 0; j < apps.length && !path; j++) {
      if (apps[j].startupClass && apps[j].startupClass.toLowerCase() === lower && apps[j].icon)
        path = root.iconSource(apps[j].icon)
    }
    if (!path) path = Quickshell.iconPath(lower, true)
    if (!path) path = Quickshell.iconPath("application-x-executable", true)
    cache.map[cls] = path
    cache.size++
    return path
  }

  // One icon per app on the workspace, most recently focused first.
  function appsFor(workspace) {
    if (!workspace) return []
    var toplevels = workspace.toplevels.values.slice(0, 64)
    toplevels.sort(function(a, b) {
      var fa = a.lastIpcObject && a.lastIpcObject.focusHistoryID !== undefined ? a.lastIpcObject.focusHistoryID : 99
      var fb = b.lastIpcObject && b.lastIpcObject.focusHistoryID !== undefined ? b.lastIpcObject.focusHistoryID : 99
      return fa - fb
    })
    var seen = {}
    var list = []
    for (var i = 0; i < toplevels.length; i++) {
      var cls = root.appClass(toplevels[i])
      if (!cls || seen[cls]) continue
      seen[cls] = true
      list.push({ name: cls, icon: root.iconFor(cls) })
      if (list.length >= 16) break
    }
    return list
  }

  // ------------------------------------------------------------ model

  function buildEntries() {
    var values = Hyprland.workspaces.values
    var existing = {}
    for (var i = 0; i < values.length; i++) existing[values[i].id] = values[i]

    // Always 1..workspaceCount, plus any other normal workspace that exists,
    // up to Safe.MAX_WORKSPACE.
    var ids = []
    for (var n = 1; n <= root.workspaceCount; n++) ids.push(n)
    for (var j = 0; j < values.length; j++) {
      var extra = Safe.workspaceId(values[j].id)
      if (extra && Number(extra) > root.workspaceCount) ids.push(Number(extra))
    }
    ids.sort(function(a, b) { return a - b })

    var list = []
    for (var k = 0; k < ids.length; k++) list.push({ id: ids[k], workspace: existing[ids[k]] || null })
    root.entries = list
  }

  function indexOfWorkspace(id) {
    for (var i = 0; i < root.entries.length; i++) if (root.entries[i].id === id) return i
    return -1
  }

  // ------------------------------------------------------------ input

  GlobalShortcut {
    appid: "chyld-vista"
    name: "next"
    onPressed: root.step(1)
  }

  GlobalShortcut {
    appid: "chyld-vista"
    name: "prev"
    onPressed: root.step(-1)
  }

  // One Tab press can arrive twice: as the compositor bind and as a key event
  // on the focused overlay. Only the first counts.
  function step(direction) {
    var now = Date.now()
    if (now - root.lastStepAt < 20) return
    root.lastStepAt = now
    if (!root.opened) root.open(direction)
    else root.cycle(direction)
  }

  function cycle(direction) {
    var n = root.entries.length
    if (n > 0) root.selectedIndex = ((root.selectedIndex + direction) % n + n) % n
  }

  function move(delta) {
    var n = root.entries.length
    if (n > 0) root.selectedIndex = Math.max(0, Math.min(n - 1, root.selectedIndex + delta))
  }

  function isSuperKey(key) {
    return key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R
  }

  // ------------------------------------------------------------ lifecycle

  function open(direction) {
    closeTimer.stop()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.targetMonitor = Hyprland.focusedMonitor
    root.buildEntries()

    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    var current = root.indexOfWorkspace(focusedId)
    // From a special or unlisted workspace, "next" starts at the first card.
    root.selectedIndex = current !== -1 ? current : (direction > 0 ? root.entries.length - 1 : 0)
    root.cycle(direction)

    root.lastPointerX = -1
    root.lastPointerY = -1
    root.openedAt = Date.now()
    root.revealed = false
    root.presented = true
    root.opened = true
    revealTimer.restart()
    releaseCheck.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commit() {
    if (!root.opened) return
    var entry = root.entries[root.selectedIndex]
    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    root.close()
    var id = entry ? Safe.workspaceId(entry.id) : ""
    if (id && entry.id !== focusedId) {
      // Hyprland.dispatch() does not speak the Lua dispatcher syntax.
      Quickshell.execDetached([root.hyprctl, "dispatch", "hl.dsp.focus({ workspace = " + Safe.luaQuote(id) + " })"])
    }
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    revealTimer.stop()
    releaseCheck.stop()
    // A quick tap never showed anything, so there is nothing to fade.
    if (root.revealed && root.animationDuration > 0) closeTimer.restart()
    else root.finishClose()
  }

  function finishClose() {
    root.presented = false
    root.revealed = false
    root.entries = []
  }

  // Delay showing the switcher so a quick SUPER+TAB tap switches without a flash.
  Timer {
    id: revealTimer
    interval: 120
    onTriggered: root.revealed = true
  }

  Timer {
    id: closeTimer
    interval: root.animationDuration + 20
    onTriggered: if (!root.opened) root.finishClose()
  }

  // Ask the compositor whether SUPER is still down while the switcher is open.
  // One query at a time, and only for the first 30 s of a session; after that
  // the overlay's own key-release event is the only trigger.
  Timer {
    id: releaseCheck
    interval: 50
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!root.opened || Date.now() - root.openedAt > 30000) { stop(); return }
      if (!superCheck.running) superCheck.running = true
    }
  }

  // The reply is a single short line; it is read in chunks under a small byte
  // budget with a deadline, and anything else counts as "not down".
  Process {
    id: superCheck
    property string buf: ""
    command: [root.hyprctl, "eval", 'error(tostring(hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (superCheck.buf.length + chunk.length > 512) { superCheck.buf = ""; superCheck.signal(15); return }
        superCheck.buf += chunk
      }
    }
    onStarted: { buf = ""; superDeadline.restart() }
    onExited: function(code) {
      superDeadline.stop()
      var reply = buf.trim()
      buf = ""
      if (root.opened && !/true$/.test(reply)) root.commit()
    }
  }

  Timer { id: superDeadline; interval: 1000; onTriggered: superCheck.signal(9) }

  // Keep window geometry fresh while open: Hyprland only updates
  // lastIpcObject on refresh.
  Connections {
    target: Hyprland
    enabled: root.presented
    function onRawEvent(event) {
      var n = event.name
      if (n === "movewindow" || n === "movewindowv2" || n === "changefloatingmode" ||
          n === "fullscreen" || n === "openwindow" || n === "closewindow" ||
          n === "windowtitle" || n === "windowtitlev2") {
        Hyprland.refreshToplevels()
      }
    }
  }


  // ------------------------------------------------------------ preview

  // A workspace drawn to scale: wallpaper, then its windows at their real
  // geometry as live screen captures. Used for the large preview and for
  // each filmstrip thumbnail.
  component WorkspacePreview: Item {
    id: wp

    property var workspace: null
    property var fallbackMonitor: null
    property bool live: false
    property bool showWallpaper: true
    property string wallpaper: ""

    readonly property var monitor: workspace && workspace.monitor ? workspace.monitor : fallbackMonitor
    readonly property real monX: monitor ? monitor.x : 0
    readonly property real monY: monitor ? monitor.y : 0
    readonly property real monW: monitor ? monitor.width / Math.max(0.1, monitor.scale) : width
    readonly property real monH: monitor ? monitor.height / Math.max(0.1, monitor.scale) : height
    readonly property real k: Math.min(width / Math.max(1, monW), height / Math.max(1, monH))
    readonly property var toplevels: workspace ? workspace.toplevels.values : []

    Rectangle {
      id: maskShape
      anchors.fill: parent
      radius: Style.cornerRadius
      visible: false
      layer.enabled: true
    }

    Item {
      anchors.fill: parent
      layer.enabled: Style.cornerRadius > 0
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: maskShape
        maskThresholdMin: 0.3
        maskSpreadAtMin: 0.3
      }

      Rectangle {
        anchors.fill: parent
        color: Color.background
      }

      Image {
        anchors.fill: parent
        visible: wp.showWallpaper
        source: wp.live && wp.showWallpaper ? "file://" + wp.wallpaper : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: wp.width * 2
        sourceSize.height: wp.height * 2
        opacity: wp.toplevels.length > 0 ? 0.85 : 0.55
      }

      Item {
        width: Math.round(wp.monW * wp.k)
        height: Math.round(wp.monH * wp.k)
        anchors.centerIn: parent

        Repeater {
          model: wp.toplevels

          Item {
            id: win

            required property var modelData

            readonly property var ipc: modelData.lastIpcObject || ({})
            readonly property bool hasGeometry: ipc.at !== undefined && ipc.size !== undefined
            readonly property int focusOrder: ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 99

            visible: hasGeometry && ipc.hidden !== true
            x: hasGeometry ? Math.round((ipc.at[0] - wp.monX) * wp.k) : 0
            y: hasGeometry ? Math.round((ipc.at[1] - wp.monY) * wp.k) : 0
            width: hasGeometry ? Math.max(2, Math.round(ipc.size[0] * wp.k)) : 0
            height: hasGeometry ? Math.max(2, Math.round(ipc.size[1] * wp.k)) : 0
            z: (ipc.fullscreen ? 2000 : ipc.floating === true ? 1000 : 0) + (500 - Math.min(499, focusOrder))

            ScreencopyView {
              id: capture
              anchors.fill: parent
              captureSource: win.modelData.wayland
              live: wp.live
              paintCursor: false
              constraintSize: Qt.size(width * 2, height * 2)
            }

            Rectangle {
              anchors.fill: parent
              visible: !capture.hasContent
              color: Util.alpha(Color.foreground, 0.10)
              border.width: 1
              border.color: Util.alpha(Color.foreground, 0.25)
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ window

  PanelWindow {
    id: panel
    visible: root.presented
    screen: {
      var screens = Quickshell.screens
      var name = root.targetMonitor ? root.targetMonitor.name : ""
      for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
      return screens.length > 0 ? screens[0] : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "chyld-vista"
    WlrLayershell.layer: WlrLayer.Overlay
    // Kept constant: dropping focus on close makes Hyprland refocus its last
    // window, which can pull the workspace back after we switched.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Item {
      id: content
      anchors.fill: parent
      opacity: root.opened && root.revealed ? 1 : 0
      Behavior on opacity {
        enabled: root.animationDuration > 0
        NumberAnimation { duration: root.animationDuration; easing.type: Easing.OutCubic }
      }

      Rectangle {
        anchors.fill: parent
        color: root.scrim
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
        onWheel: function(wheel) {
          var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
          if (delta !== 0) root.move(delta > 0 ? -1 : 1)
        }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          var key = event.key
          if (key === Qt.Key_Escape) root.close()
          else if (key === Qt.Key_Backtab || (key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) root.step(-1)
          else if (key === Qt.Key_Tab) root.step(1)
          else if (key === Qt.Key_Left || key === Qt.Key_H) root.move(-1)
          else if (key === Qt.Key_Right || key === Qt.Key_L) root.move(1)
          else if (key === Qt.Key_Return || key === Qt.Key_Enter) root.commit()
          else if (key >= Qt.Key_0 && key <= Qt.Key_9) {
            var index = root.indexOfWorkspace(key === Qt.Key_0 ? 10 : key - Qt.Key_0)
            if (index !== -1) { root.selectedIndex = index; root.commit() }
          } else return
          event.accepted = true
        }

        Keys.onReleased: function(event) {
          if (root.isSuperKey(event.key)) root.commit()
        }
      }

      Column {
        anchors.centerIn: parent
        spacing: Style.space(20)

        // Large live preview of the selected workspace.
        Item {
          width: root.heroWidth
          height: root.heroHeight
          anchors.horizontalCenter: parent.horizontalCenter

          WorkspacePreview {
            anchors.fill: parent
            workspace: root.selectedEntry ? root.selectedEntry.workspace : null
            fallbackMonitor: root.targetMonitor
            live: root.presented
            showWallpaper: root.showWallpaper
            wallpaper: root.backgroundPath
          }

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: "transparent"
            border.width: root.borderWidth
            border.color: root.selectedBorder
          }

          MouseArea {
            anchors.fill: parent
            onClicked: root.commit()
          }
        }

        // Big workspace number, then the apps on it and its last window title.
        Item {
          width: root.heroWidth
          height: heroNumber.height
          anchors.horizontalCenter: parent.horizontalCenter

          Row {
            spacing: Style.space(18)

            Text {
              id: heroNumber
              textFormat: Text.PlainText
              text: root.selectedEntry ? String(root.selectedEntry.id) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.heroNumberSize
              font.weight: Font.Bold
            }

            Column {
              anchors.verticalCenter: heroNumber.verticalCenter
              spacing: Style.space(8)

              Row {
                visible: root.showIcons && heroApps.count > 0
                spacing: Style.space(8)

                Repeater {
                  id: heroApps
                  model: root.showIcons && root.selectedEntry ? root.appsFor(root.selectedEntry.workspace) : []

                  Image {
                    required property var modelData
                    width: root.heroIconSize
                    height: root.heroIconSize
                    sourceSize.width: width * 2
                    sourceSize.height: height * 2
                    source: modelData.icon
                    smooth: true
                    asynchronous: true
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: root.heroWidth - heroNumber.width - Style.space(18)
                elide: Text.ElideRight
                text: {
                  var ws = root.selectedEntry ? root.selectedEntry.workspace : null
                  if (!ws || ws.toplevels.values.length === 0) return "Empty workspace"
                  var ipc = ws.lastIpcObject || {}
                  return ipc.lastwindowtitle ? Safe.title(ipc.lastwindowtitle) : ""
                }
                color: Util.alpha(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }
            }
          }
        }

        // Filmstrip of every workspace, with a bar sliding under the selection.
        Item {
          width: strip.width
          height: strip.height + Style.space(10)
          anchors.horizontalCenter: parent.horizontalCenter

          Row {
            id: strip
            spacing: root.thumbGap

            Repeater {
              model: root.entries

              Column {
                id: thumb

                required property var modelData
                required property int index

                readonly property bool selected: index === root.selectedIndex
                readonly property bool current: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData.id
                readonly property var apps: root.showIcons ? root.appsFor(modelData.workspace) : []

                spacing: Style.space(6)
                opacity: selected ? 1 : 0.6
                Behavior on opacity { enabled: root.animationDuration > 0; NumberAnimation { duration: root.animationDuration } }

                Item {
                  width: root.thumbWidth
                  height: root.thumbHeight

                  WorkspacePreview {
                    anchors.fill: parent
                    workspace: thumb.modelData.workspace
                    fallbackMonitor: root.targetMonitor
                    live: root.presented
                    showWallpaper: root.showWallpaper
                    wallpaper: root.backgroundPath
                  }

                  // Big number over the thumbnail, shadowed to read on any preview.
                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: String(thumb.modelData.id)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(root.thumbHeight * 0.55)
                    font.weight: Font.Bold
                    layer.enabled: true
                    layer.effect: MultiEffect {
                      shadowEnabled: true
                      shadowColor: root.scrim
                      shadowBlur: 0.6
                      shadowOpacity: 1
                    }
                  }

                  // Dot on the workspace you are on now.
                  Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Style.space(6)
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: root.selectedBorder
                    visible: thumb.current
                  }

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: 1
                    border.color: thumb.selected ? root.selectedBorder : root.unselectedBorder
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    // Select on real pointer motion only.
                    onPositionChanged: function(mouse) {
                      var p = mapToItem(null, mouse.x, mouse.y)
                      var moved = root.lastPointerX >= 0
                        && (Math.abs(p.x - root.lastPointerX) > 2 || Math.abs(p.y - root.lastPointerY) > 2)
                      root.lastPointerX = p.x
                      root.lastPointerY = p.y
                      if (moved) root.selectedIndex = thumb.index
                    }
                    onClicked: {
                      root.selectedIndex = thumb.index
                      root.commit()
                    }
                  }
                }

                // Up to four app icons, then a count of the rest.
                Row {
                  visible: root.showIcons
                  height: root.thumbIconSize
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(4)

                  Repeater {
                    model: thumb.apps.slice(0, 4)

                    Image {
                      required property var modelData
                      width: root.thumbIconSize
                      height: root.thumbIconSize
                      sourceSize.width: width * 2
                      sourceSize.height: height * 2
                      source: modelData.icon
                      smooth: true
                      asynchronous: true
                    }
                  }

                  Text {
                    visible: thumb.apps.length > 4
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "+" + (thumb.apps.length - 4)
                    color: Util.alpha(root.foreground, 0.7)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            x: root.selectedIndex * (root.thumbWidth + root.thumbGap)
            width: root.thumbWidth
            height: Style.space(3)
            radius: height / 2
            color: root.selectedBorder
            Behavior on x {
              enabled: root.animationDuration > 0
              NumberAnimation { duration: root.animationDuration; easing.type: Easing.OutCubic }
            }
          }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(28)
        textFormat: Text.PlainText
        text: "tab next   shift+tab previous   release super to switch   esc cancel"
        color: Util.alpha(root.foreground, 0.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
