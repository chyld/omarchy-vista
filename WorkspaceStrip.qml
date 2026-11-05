import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Safe.js" as Safe
import "Hypr.js" as Hypr
import "Strip.js" as Strip

// Vista's workspace strip in the bar: a pill per workspace with an icon per
// window on it, then the settings gear. Click a pill to switch, an icon to
// focus its window, scroll to move along this bar's monitor.
//
// Workspace numbers are Hyprland's global ids, the same on every bar and the
// same list the Super+Tab switcher shows (Strip.workspaceIds).
//
// Input goes through the bar's own contract: its MouseArea covers every
// widget and hands left clicks only to registered click targets (each pill,
// and the gear, which registers itself as a WidgetButton), and its tooltips
// show only for items reporting tooltipHovered (each icon). The only other
// MouseAreas are the gear's and a button-less one beneath the pills that
// catches the wheel.
//
// The Repeaters' models (ids, and each pill's windows) are only replaced when
// their contents change: a new array would make a Repeater destroy and
// recreate every pill and icon, dropping hover and tooltips.
Item {
  id: strip

  property var bar: null
  property color foreground: Color.foreground
  property int workspaceCount: 5
  property bool showIcons: true
  property bool showNumbers: true
  property bool settingsOpen: false
  readonly property alias gear: gearButton

  signal settingsRequested()

  readonly property bool vertical: strip.bar ? strip.bar.vertical === true : false
  readonly property real barSize: strip.bar && strip.bar.barSize > 0 ? strip.bar.barSize : Style.bar.sizeHorizontal
  readonly property real thickness: Math.max(Style.space(12), strip.barSize - Style.space(8))
  readonly property real iconSize: Math.max(Style.space(12), Math.min(Style.space(18), strip.barSize - Style.space(12)))
  readonly property int iconCap: strip.vertical ? Strip.MAX_ICONS_VERTICAL : Strip.MAX_ICONS
  readonly property real gap: Style.space(6)

  implicitWidth: strip.vertical ? strip.barSize : pills.width + (strip.visibleIds.length > 0 ? strip.gap : 0) + gearButton.width
  implicitHeight: strip.vertical ? pills.height + (strip.visibleIds.length > 0 ? strip.gap : 0) + gearButton.height : strip.barSize

  // ------------------------------------------------------------ model

  // The monitor this bar is on. With a screen Hyprland does not know, there is
  // none: no "this monitor" highlight, and scrolling does nothing.
  readonly property var monitor: {
    // monitorFor() notifies nothing; reading the list re-resolves on hotplug.
    Hyprland.monitors.values
    Hyprland.focusedMonitor
    var window = strip.QsWindow.window
    var screen = window ? window.screen : null
    if (screen) return Hyprland.monitorFor(screen) || null
    return Hyprland.focusedMonitor
  }

  // This bar's monitor as an output name, or "" when unknown. Clicks from a
  // known monitor leave the pointer on the bar (Hypr.bar*). Only the bar's own
  // screen counts: `monitor` falls back to the focused one without a screen,
  // and comparing the focused monitor with itself would move the pointer off
  // the bar; unknown gives Hyprland's plain dispatch instead.
  readonly property string barOutput: {
    var window = strip.QsWindow.window
    var screen = window ? window.screen : null
    return screen && strip.monitor ? Safe.outputName(String(strip.monitor.name)) : ""
  }

  // Bumped after each refresh: lastIpcObject (the window class) changes only
  // when Hyprland's model is refreshed, which nothing else would notify.
  property int revision: 0

  readonly property var freshIds: {
    strip.revision
    var values = Hyprland.workspaces.values
    var raw = []
    for (var i = 0; i < values.length && i < 200; i++) raw.push(values[i].id)
    return Strip.workspaceIds(strip.workspaceCount, raw)
  }
  property var ids: []
  onFreshIdsChanged: if (!Strip.sameList(strip.ids, strip.freshIds)) strip.ids = strip.freshIds

  // Pills actually drawn. With numbers shown, every workspace gets a pill.
  // With numbers hidden, a pill with no icons to show would be an empty box,
  // so only workspaces with something visible get one. With both numbers and
  // icons off there is nothing to draw: no pills, just the gear.
  readonly property var visibleIds: {
    strip.revision
    if (strip.showNumbers) return strip.ids
    if (!strip.showIcons) return []
    var out = []
    for (var i = 0; i < strip.ids.length; i++) {
      var ws = strip.workspaceById(strip.ids[i])
      if (ws && ws.toplevels.values.length > 0) out.push(strip.ids[i])
    }
    return out
  }

  // Existing workspace id -> its monitor's output name.
  readonly property var owners: {
    strip.revision
    var values = Hyprland.workspaces.values
    var map = Object.create(null)
    for (var i = 0; i < values.length && i < 200; i++) {
      var id = Safe.workspaceId(values[i].id)
      if (id) map[id] = values[i].monitor ? String(values[i].monitor.name) : ""
    }
    return map
  }

  // Workspace id -> output name of the monitor showing it.
  readonly property var shown: {
    var values = Hyprland.monitors.values
    var map = Object.create(null)
    for (var i = 0; i < values.length && i < 16; i++) {
      var ws = values[i].activeWorkspace
      var id = ws ? Safe.workspaceId(ws.id) : ""
      if (id) map[id] = String(values[i].name)
    }
    return map
  }

  // How much of the screen the strip may take along the bar: on a horizontal
  // bar it stops well short of the centred clock. When the pills would not
  // fit, each shows fewer icons (Strip.fitIcons), down to numbers and "+N".
  readonly property real budget: {
    var window = strip.QsWindow.window
    var screen = window ? window.screen : null
    if (!screen) return 0
    return strip.vertical ? screen.height * 0.6 : screen.width * 0.4
  }

  readonly property var windowCounts: {
    strip.revision
    var counts = []
    for (var i = 0; i < strip.visibleIds.length; i++) {
      var ws = strip.workspaceById(strip.visibleIds[i])
      counts.push(ws ? ws.toplevels.values.length : 0)
    }
    return counts
  }

  readonly property int maxIcons: {
    var spacing = Style.space(6)
    var numberLength = strip.vertical ? Style.font.body * 1.3 : Style.font.body * 1.2
    return Strip.fitIcons(strip.windowCounts, strip.iconCap, {
      fixed: strip.gap + (strip.vertical ? gearButton.height : gearButton.width) + Math.max(0, strip.visibleIds.length - 1) * Style.space(4),
      pill: Style.space(16) + numberLength,
      icon: strip.iconSize + spacing,
      more: spacing + Style.font.caption * 1.6
    }, strip.budget)
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length && i < 200; i++) if (values[i].id === id) return values[i]
    return null
  }

  AppIcons { id: icons }

  // ------------------------------------------------------------ actions

  function run(argv) {
    if (argv) Quickshell.execDetached(argv)
  }

  // Switch to a workspace from this bar. One already shown here only needs
  // this monitor focused; an existing one is shown where it lives (focus
  // follows, as with the switcher); a new one is created on this monitor.
  // The pointer stays on the bar unless focus lands on another monitor.
  function activate(id) {
    var m = strip.monitor
    var action = Strip.pillAction(id, m ? { activeId: m.activeWorkspace ? m.activeWorkspace.id : -1, focused: m.focused === true } : null,
                                  strip.workspaceById(id) !== null)
    strip.run(Hypr.barAction(action, id, strip.barOutput))
  }

  // A wheel notch moves one workspace along this monitor's; touchpad deltas
  // add up to a notch. Holds at the ends.
  property real wheelAccumulator: 0

  function scroll(delta) {
    var wheel = Util.wheelSteps(strip.wheelAccumulator, delta)
    strip.wheelAccumulator = wheel.remainder
    var m = strip.monitor
    if (wheel.steps === 0 || !m || !m.activeWorkspace) return
    var current = m.activeWorkspace.id
    var target = Strip.scrollTarget(Strip.scrollIds(strip.ids, strip.owners, String(m.name)), current, wheel.steps)
    if (target > 0 && target !== current) strip.activate(target)
  }

  function showTip(target, text) {
    if (strip.bar && text) strip.bar.showTooltip(target, text)
  }

  function hideTip(target) {
    if (strip.bar) strip.bar.hideTooltip(target)
  }

  // Takes no buttons, so clicks still reach the bar's own MouseArea; it only
  // catches the wheel, on either axis and from a mouse or a touchpad (a
  // WheelHandler defaults to vertical mouse wheels only). Declared before the
  // pills, so it sits beneath them; they have no MouseAreas to stop it.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) { strip.scroll(wheel.angleDelta.y || wheel.angleDelta.x) }
  }

  // ------------------------------------------------------------ refresh

  // Refreshing updates the model every bar reads, so only the bar on the
  // focused monitor asks. Every bar bumps its own revision afterwards.
  readonly property bool asks: !Hyprland.focusedMonitor || strip.monitor === Hyprland.focusedMonitor

  readonly property var workspaceEvents: ({
    workspacev2: true, moveworkspacev2: true, changeworkspaceid: true, createworkspacev2: true,
    destroyworkspacev2: true, focusedmon: true, monitoraddedv2: true, monitorremovedv2: true, configreloaded: true
  })
  readonly property var windowEvents: ({
    openwindow: true, closewindow: true, movewindow: true, movewindowv2: true
  })

  // Timers throttle rather than debounce (start only when idle), so a burst of
  // events can't hold a refresh off indefinitely. Title changes need neither:
  // toplevel.title notifies by itself.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (strip.workspaceEvents[name] === true) {
        if (strip.asks) { Hyprland.refreshMonitors(); Hyprland.refreshWorkspaces() }
        if (!revisionTimer.running) revisionTimer.start()
      } else if (strip.windowEvents[name] === true) {
        if (strip.asks && !toplevelTimer.running) toplevelTimer.start()
        if (!revisionTimer.running) revisionTimer.start()
      }
    }
  }

  Timer {
    id: toplevelTimer
    interval: 100
    onTriggered: Hyprland.refreshToplevels()
  }

  Timer {
    id: revisionTimer
    interval: 250
    onTriggered: strip.revision++
  }

  Component.onCompleted: {
    strip.ids = strip.freshIds
    if (strip.asks) { Hyprland.refreshMonitors(); Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() }
    revisionTimer.restart()
  }

  // ------------------------------------------------------------ view

  Grid {
    id: pills
    x: strip.vertical ? (strip.width - width) / 2 : 0
    y: strip.vertical ? 0 : (strip.height - height) / 2
    columns: strip.vertical ? 1 : Math.max(1, strip.visibleIds.length)
    spacing: Style.space(4)
    visible: strip.visibleIds.length > 0

    Repeater {
      model: strip.visibleIds

      Item {
        id: pill
        required property int modelData
        readonly property int workspaceId: modelData

        readonly property var workspace: { strip.revision; return strip.workspaceById(pill.workspaceId) }
        readonly property var toplevelList: pill.workspace ? pill.workspace.toplevels.values : []
        readonly property bool occupied: pill.toplevelList.length > 0
        readonly property var freshWindows: { strip.revision; return Strip.windowsFor(pill.toplevelList, strip.showIcons ? strip.maxIcons : 0) }
        property var windows: ({ shown: [], hidden: 0 })
        onFreshWindowsChanged: if (Strip.windowsKey(pill.windows) !== Strip.windowsKey(pill.freshWindows)) pill.windows = pill.freshWindows
        // With app icons off a pill is just its number: no "+N" either.
        readonly property int overflow: strip.showIcons ? pill.windows.hidden : 0
        readonly property string key: String(pill.workspaceId)
        readonly property string shownOn: strip.shown[pill.key] || ""
        readonly property bool shownHere: strip.monitor !== null && pill.shownOn !== "" && pill.shownOn === String(strip.monitor.name)
        readonly property string look: Strip.pillState(pill.shownHere, pill.shownOn !== "" && !pill.shownHere, pill.occupied)

        // The icon under the pointer, so a press on the pill can tell an
        // icon click from a click on the number.
        property string hoveredAddress: ""

        // Click target contract (Bar.qml moduleTargetClickable).
        readonly property bool interactive: true
        readonly property bool pressable: true
        readonly property bool concealed: false
        // Set by the bar while it holds a press on this pill: press feedback.
        property int heldButtons: Qt.NoButton
        property var registeredBar: null

        function triggerPress(button) {
          if (button !== Qt.LeftButton) return
          if (pill.hoveredAddress) strip.run(Hypr.barFocusWindow(pill.hoveredAddress, strip.barOutput))
          else strip.activate(pill.workspaceId)
        }

        function syncRegistration() {
          if (pill.registeredBar && pill.registeredBar.unregisterClickTarget) pill.registeredBar.unregisterClickTarget(pill)
          pill.registeredBar = strip.bar
          if (pill.registeredBar && pill.registeredBar.registerClickTarget) pill.registeredBar.registerClickTarget(pill)
        }

        Connections {
          target: strip
          function onBarChanged() { pill.syncRegistration() }
        }
        Component.onCompleted: {
          pill.windows = pill.freshWindows
          pill.syncRegistration()
        }
        Component.onDestruction: if (pill.registeredBar && pill.registeredBar.unregisterClickTarget) pill.registeredBar.unregisterClickTarget(pill)

        width: strip.vertical ? strip.thickness : content.width + Style.space(16)
        height: strip.vertical ? content.height + Style.space(16) : strip.thickness

        HoverHandler { id: pillHover }

        Rectangle {
          anchors.fill: parent
          radius: Math.min(Math.max(Style.cornerRadius, Style.space(6)), strip.thickness / 2)
          readonly property real fill: pill.look === "here" ? 0.14
            : (pill.look === "elsewhere" && pill.occupied) || pill.look === "occupied" ? 0.06 : 0
          color: Util.alpha(strip.foreground, fill + (pillHover.hovered ? 0.06 : 0))
          border.width: pill.look === "here" || pill.look === "elsewhere" ? 1 : 0
          border.color: pill.look === "here" ? Util.alpha(Color.accent, 0.6) : Util.alpha(strip.foreground, 0.25)
        }

        Grid {
          id: content
          anchors.centerIn: parent
          // Gives a little while pressed, as Omarchy's own buttons do: only the
          // contents shrink, so the pill and its hit area hold still.
          scale: pill.heldButtons & Qt.LeftButton ? 0.9 : 1
          Behavior on scale {
            NumberAnimation { duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
          }
          columns: strip.vertical ? 1 : (strip.showNumbers ? 1 : 0) + pill.windows.shown.length + (pill.overflow > 0 ? 1 : 0)
          spacing: Style.space(6)
          horizontalItemAlignment: Grid.AlignHCenter
          verticalItemAlignment: Grid.AlignVCenter

          Text {
            visible: strip.showNumbers
            width: strip.showNumbers ? implicitWidth : 0
            height: strip.showNumbers ? implicitHeight : 0
            textFormat: Text.PlainText
            text: pill.key
            color: strip.foreground
            opacity: pill.look === "empty" ? 0.5 : 1
            font.family: strip.bar && strip.bar.fontFamily ? strip.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.features: { "tnum": 1 }
          }

          Repeater {
            model: pill.windows.shown

            Item {
              id: icon
              required property var modelData
              readonly property var toplevel: modelData.toplevel
              readonly property string address: modelData.address
              readonly property bool focusedWindow: !!Hyprland.activeToplevel && Hyprland.activeToplevel === icon.toplevel
              readonly property bool tooltipHovered: icon.visible && icon.opacity > 0 && iconHover.hovered
              readonly property string tipText: Safe.plain(icon.toplevel ? icon.toplevel.title : "", 64)

              width: strip.iconSize
              height: strip.iconSize

              // A title that changes while hovered updates the tooltip, and
              // one that becomes empty hides it.
              onTipTextChanged: {
                if (!iconHover.hovered) return
                if (icon.tipText) strip.showTip(icon, icon.tipText)
                else strip.hideTip(icon)
              }

              // Stays inside the pill however tight the bar is.
              Rectangle {
                anchors.centerIn: parent
                width: Math.min(parent.width + Style.space(6), strip.thickness - 2)
                height: width
                radius: Math.min(Math.max(Style.cornerRadius / 2, Style.space(3)), height / 2)
                color: icon.focusedWindow ? Util.alpha(strip.foreground, 0.16) : "transparent"
              }

              Image {
                anchors.fill: parent
                source: { strip.revision; return icons.windowIcon(icon.toplevel) }
                sourceSize.width: Math.round(strip.iconSize * 2)
                sourceSize.height: Math.round(strip.iconSize * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
              }

              HoverHandler {
                id: iconHover
                onHoveredChanged: {
                  if (hovered) {
                    pill.hoveredAddress = icon.address
                    strip.showTip(icon, icon.tipText)
                  } else {
                    if (pill.hoveredAddress === icon.address) pill.hoveredAddress = ""
                    strip.hideTip(icon)
                  }
                }
              }

              Component.onDestruction: {
                if (pill.hoveredAddress === icon.address) pill.hoveredAddress = ""
                strip.hideTip(icon)
              }
            }
          }

          Text {
            visible: pill.overflow > 0
            textFormat: Text.PlainText
            text: "+" + pill.overflow
            color: Util.alpha(strip.foreground, 0.7)
            font.family: strip.bar && strip.bar.fontFamily ? strip.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  BarIconButton {
    id: gearButton
    x: strip.vertical ? (strip.width - width) / 2 : pills.width + (strip.visibleIds.length > 0 ? strip.gap : 0)
    y: strip.vertical ? pills.height + (strip.visibleIds.length > 0 ? strip.gap : 0) : (strip.height - height) / 2
    bar: strip.bar
    text: "\u{f0493}"   // nf-md-cog
    tooltipText: strip.settingsOpen ? "" : "Vista settings"
    onPressed: function(button) { if (button === Qt.LeftButton) strip.settingsRequested() }
    onWheelMoved: function(delta) { strip.scroll(delta) }
  }
}
