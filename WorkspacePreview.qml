import QtQuick
import QtQuick.Effects
import Quickshell.Wayland
import qs.Commons

// One workspace drawn to scale: the wallpaper, then its windows at their real
// geometry as screen captures, clipped to the theme's corner radius.
//
// `live` keeps the captures updating; otherwise each window is captured once.
// Windows on hidden workspaces do not repaint anyway, so only the large
// preview needs to be live.
Item {
  id: preview

  property var workspace: null
  property var fallbackMonitor: null
  property bool active: false          // capture at all (the switcher is showing)
  property bool live: false            // keep capturing while active
  property bool showWallpaper: true
  property string wallpaper: ""

  readonly property var monitor: workspace && workspace.monitor ? workspace.monitor : fallbackMonitor
  readonly property real monX: monitor ? monitor.x : 0
  readonly property real monY: monitor ? monitor.y : 0
  readonly property real monW: monitor ? monitor.width / Math.max(0.1, monitor.scale) : width
  readonly property real monH: monitor ? monitor.height / Math.max(0.1, monitor.scale) : height
  readonly property real k: Math.min(width / Math.max(1, monW), height / Math.max(1, monH))
  // At most 32 windows per preview, most recently focused first, so a crowded
  // workspace cannot start an unbounded number of screen captures.
  readonly property var toplevels: {
    if (!workspace || !active) return []
    var list = workspace.toplevels.values.slice(0, 256)
    list.sort(function(a, b) { return focusOf(a) - focusOf(b) })
    return list.slice(0, 32)
  }

  function focusOf(toplevel) {
    var ipc = toplevel.lastIpcObject
    return ipc && ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 99
  }

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
      visible: preview.showWallpaper
      source: preview.active && preview.showWallpaper && preview.wallpaper !== "" ? "file://" + preview.wallpaper : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: preview.width * 2
      sourceSize.height: preview.height * 2
      opacity: preview.toplevels.length > 0 ? 0.85 : 0.55
    }

    Item {
      width: Math.round(preview.monW * preview.k)
      height: Math.round(preview.monH * preview.k)
      anchors.centerIn: parent

      Repeater {
        model: preview.toplevels

        Item {
          id: win

          required property var modelData

          readonly property var ipc: modelData.lastIpcObject || ({})
          // Hyprland's IPC geometry arrives as Qt lists, not JS arrays.
          readonly property bool hasGeometry: !!ipc.at && !!ipc.size && ipc.at.length === 2 && ipc.size.length === 2
          readonly property int focusOrder: ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 99

          visible: hasGeometry && ipc.hidden !== true
          x: hasGeometry ? Math.round((ipc.at[0] - preview.monX) * preview.k) : 0
          y: hasGeometry ? Math.round((ipc.at[1] - preview.monY) * preview.k) : 0
          width: hasGeometry ? Math.max(2, Math.round(ipc.size[0] * preview.k)) : 0
          height: hasGeometry ? Math.max(2, Math.round(ipc.size[1] * preview.k)) : 0
          // Fullscreen over floating over tiled; within each, most recently focused on top.
          z: (ipc.fullscreen ? 2000 : ipc.floating === true ? 1000 : 0) + (500 - Math.min(499, focusOrder))

          ScreencopyView {
            id: capture
            anchors.fill: parent
            captureSource: win.modelData.wayland
            live: preview.live
            paintCursor: false
            constraintSize: Qt.size(width * 2, height * 2)
          }

          // Until a frame arrives, or if the window cannot be captured.
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
