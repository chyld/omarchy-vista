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
// widget and hands left clicks only to registered click targets (each pill),
// and its tooltips show only for items reporting tooltipHovered (each icon).
// Nothing here is a MouseArea, so the wheel reaches the WheelHandler.
Item {
  id: strip

  property var bar: null
  property color foreground: Color.foreground
  property int workspaceCount: 5
  property bool showIcons: true
  property bool settingsOpen: false
  readonly property alias gear: gearButton

  signal settingsRequested()

  readonly property bool vertical: strip.bar ? strip.bar.vertical === true : false
  readonly property real barSize: strip.bar && strip.bar.barSize > 0 ? strip.bar.barSize : Style.bar.sizeHorizontal
  readonly property real thickness: Math.max(Style.space(12), strip.barSize - Style.space(8))
  readonly property real iconSize: Math.max(Style.space(12), Math.min(Style.space(18), strip.barSize - Style.space(12)))
  readonly property int maxIcons: strip.vertical ? Strip.MAX_ICONS_VERTICAL : Strip.MAX_ICONS
  readonly property real gap: Style.space(6)

  implicitWidth: strip.vertical ? strip.barSize : pills.width + strip.gap + gearButton.width
  implicitHeight: strip.vertical ? pills.height + strip.gap + gearButton.height : strip.barSize

  // ------------------------------------------------------------ model

  // The monitor this bar is on. With a screen Hyprland does not know, there is
  // none: no "this monitor" highlight, and scrolling does nothing.
  readonly property var monitor: {
    var window = strip.QsWindow.window
    var screen = window ? window.screen : null
    if (screen) return Hyprland.monitorFor(screen) || null
    return Hyprland.focusedMonitor
  }

  // Bumped after each refresh: lastIpcObject (the window class) changes only
  // when Hyprland's model is refreshed, which nothing else would notify.
  property int revision: 0

  readonly property var ids: {
    strip.revision
    var values = Hyprland.workspaces.values
    var raw = []
    for (var i = 0; i < values.length && i < 200; i++) raw.push(values[i].id)
    return Strip.workspaceIds(strip.workspaceCount, raw)
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
  function activate(id) {
    var m = strip.monitor
    if (m && m.activeWorkspace && m.activeWorkspace.id === id) {
      if (!m.focused) strip.run(Hypr.focusMonitor(String(m.name)))
      return
    }
    if (strip.workspaceById(id) || !m) strip.run(Hypr.focusWorkspace(id))
    else strip.run(Hypr.focusWorkspaceOn(id, String(m.name)))
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

  WheelHandler {
    target: null
    onWheel: function(event) { strip.scroll(event.angleDelta.y || event.angleDelta.x) }
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
    openwindow: true, closewindow: true, movewindow: true, movewindowv2: true, windowtitlev2: true
  })

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (strip.workspaceEvents[name] === true) {
        if (strip.asks) { Hyprland.refreshMonitors(); Hyprland.refreshWorkspaces() }
        revisionTimer.restart()
      } else if (strip.windowEvents[name] === true) {
        if (strip.asks) toplevelTimer.restart()
        revisionTimer.restart()
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
    if (strip.asks) { Hyprland.refreshMonitors(); Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels() }
    revisionTimer.restart()
  }

  // ------------------------------------------------------------ view

  Grid {
    id: pills
    x: strip.vertical ? (strip.width - width) / 2 : 0
    y: strip.vertical ? 0 : (strip.height - height) / 2
    columns: strip.vertical ? 1 : Math.max(1, strip.ids.length)
    spacing: Style.space(4)

    Repeater {
      model: strip.ids

      Item {
        id: pill
        required property int modelData
        readonly property int workspaceId: modelData

        readonly property var workspace: { strip.revision; return strip.workspaceById(pill.workspaceId) }
        readonly property var toplevelList: pill.workspace ? pill.workspace.toplevels.values : []
        readonly property bool occupied: pill.toplevelList.length > 0
        readonly property var windows: { strip.revision; return Strip.windowsFor(pill.toplevelList, strip.showIcons ? strip.maxIcons : 0) }
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
        property var registeredBar: null

        function triggerPress(button) {
          if (button !== Qt.LeftButton) return
          if (pill.hoveredAddress) strip.run(Hypr.focusWindow(pill.hoveredAddress))
          else strip.activate(pill.workspaceId)
        }

        function syncRegistration() {
          if (pill.registeredBar) pill.registeredBar.unregisterClickTarget(pill)
          pill.registeredBar = strip.bar
          if (pill.registeredBar) pill.registeredBar.registerClickTarget(pill)
        }

        Connections {
          target: strip
          function onBarChanged() { pill.syncRegistration() }
        }
        Component.onCompleted: pill.syncRegistration()
        Component.onDestruction: if (pill.registeredBar) pill.registeredBar.unregisterClickTarget(pill)

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
          columns: strip.vertical ? 1 : 1 + pill.windows.shown.length + (pill.overflow > 0 ? 1 : 0)
          spacing: Style.space(6)
          horizontalItemAlignment: Grid.AlignHCenter
          verticalItemAlignment: Grid.AlignVCenter

          Text {
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

              Rectangle {
                anchors.centerIn: parent
                width: parent.width + Style.space(6)
                height: parent.height + Style.space(6)
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
    x: strip.vertical ? (strip.width - width) / 2 : pills.width + strip.gap
    y: strip.vertical ? pills.height + strip.gap : (strip.height - height) / 2
    bar: strip.bar
    text: "\u{f0493}"   // nf-md-cog
    tooltipText: strip.settingsOpen ? "" : "Vista settings"
    onPressed: function(button) { strip.settingsRequested() }
    onWheelMoved: function(delta) { strip.scroll(delta) }
  }
}
