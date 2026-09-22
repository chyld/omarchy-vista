import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Safe.js" as Safe

// The switcher overlay: a large live preview of the selected workspace, its
// number, app icons and last window title, and a filmstrip of every workspace
// with a bar under the selection.
//
// A view only: all state and actions live on `vista` (Service.qml).
PanelWindow {
  id: panel

  required property var vista
  required property var icons

  // ------------------------------------------------------------ theme

  // Borders and text share the image-picker tokens, so themes that style the
  // theme and background pickers style the switcher too. The backdrop is a
  // near-opaque wash of the theme background: the switcher replaces the
  // screen while it is open instead of floating over a busy page.
  readonly property color scrim: Util.alpha(Color.background, 0.96)
  readonly property color foreground: Color.imagePicker.text
  readonly property color selectedBorder: Color.imagePicker.selectedBorder
  readonly property color unselectedBorder: Color.imagePicker.unselectedBorder
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int duration: vista.animationDuration

  // ------------------------------------------------------------ geometry

  readonly property var monitor: vista.targetMonitor
  readonly property real monitorWidth: monitor ? monitor.width / Math.max(0.1, monitor.scale) : 1440
  readonly property real monitorHeight: monitor ? monitor.height / Math.max(0.1, monitor.scale) : 900
  readonly property real aspect: monitorHeight / Math.max(1, monitorWidth)
  // The large preview takes previewSize of the screen width, but never so much
  // height that the number row and filmstrip no longer fit beneath it.
  readonly property int heroWidth: Math.round(Math.min(monitorWidth * vista.previewSize, monitorHeight * 0.55 / aspect))
  readonly property int heroHeight: Math.round(heroWidth * aspect)
  readonly property int heroNumberSize: Math.max(Style.font.body * 4, Math.round(heroHeight * 0.16))
  readonly property int heroIconSize: Style.space(28)
  readonly property int thumbGap: Style.space(vista.gap)
  // Thumbnails shrink so the filmstrip always fits on screen.
  readonly property int thumbWidth: {
    var n = Math.max(1, vista.entries.length)
    var fit = Math.floor((monitorWidth - Style.space(128) - (n - 1) * thumbGap) / n)
    return Math.max(Style.space(48), Math.min(Style.space(vista.thumbnailWidth), fit))
  }
  readonly property int thumbHeight: Math.round(thumbWidth * aspect)
  readonly property int thumbIconSize: Style.space(16)
  readonly property var selected: vista.selectedEntry

  // Hover selects only on real pointer motion, not when the strip appears
  // under a resting cursor.
  property real lastPointerX: -1
  property real lastPointerY: -1

  function focusKeys() {
    panel.lastPointerX = -1
    panel.lastPointerY = -1
    keyCatcher.forceActiveFocus()
  }

  // ------------------------------------------------------------ window

  visible: vista.presented
  screen: {
    var screens = Quickshell.screens
    var name = monitor ? monitor.name : ""
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
    anchors.fill: parent
    opacity: vista.opened && vista.revealed ? 1 : 0
    Behavior on opacity {
      enabled: panel.duration > 0
      NumberAnimation { duration: panel.duration; easing.type: Easing.OutCubic }
    }

    Rectangle {
      anchors.fill: parent
      color: panel.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: vista.close()
      onWheel: function(wheel) {
        var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
        if (delta !== 0) vista.move(delta > 0 ? -1 : 1)
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var key = event.key
        if (key === Qt.Key_Escape) vista.close()
        else if (key === Qt.Key_Backtab || (key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) vista.step(-1)
        else if (key === Qt.Key_Tab) vista.step(1)
        else if (key === Qt.Key_Left || key === Qt.Key_H) vista.move(-1)
        else if (key === Qt.Key_Right || key === Qt.Key_L) vista.move(1)
        else if (key === Qt.Key_Return || key === Qt.Key_Enter) vista.commit()
        else if (key >= Qt.Key_0 && key <= Qt.Key_9) vista.jump(key === Qt.Key_0 ? 10 : key - Qt.Key_0)
        else return
        event.accepted = true
      }

      Keys.onReleased: function(event) {
        var key = event.key
        if (key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R) vista.commit()
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(20)

      // ---------------------------------------------------------- large preview

      Item {
        width: panel.heroWidth
        height: panel.heroHeight
        anchors.horizontalCenter: parent.horizontalCenter

        WorkspacePreview {
          anchors.fill: parent
          workspace: panel.selected ? panel.selected.workspace : null
          fallbackMonitor: panel.monitor
          active: vista.presented
          live: true
          showWallpaper: vista.showWallpaper
          wallpaper: vista.wallpaperPath
        }

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: "transparent"
          border.width: Math.max(2, Style.space(2))
          border.color: panel.selectedBorder
        }

        MouseArea {
          anchors.fill: parent
          onClicked: vista.commit()
        }
      }

      // ---------------------------------------------------------- number, apps, title

      Item {
        width: panel.heroWidth
        height: heroNumber.height
        anchors.horizontalCenter: parent.horizontalCenter

        Row {
          spacing: Style.space(18)

          Text {
            id: heroNumber
            textFormat: Text.PlainText
            text: panel.selected ? String(panel.selected.id) : ""
            color: panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: panel.heroNumberSize
            font.weight: Font.Bold
          }

          Column {
            anchors.verticalCenter: heroNumber.verticalCenter
            spacing: Style.space(8)

            Row {
              visible: vista.showIcons && heroApps.count > 0
              spacing: Style.space(8)

              Repeater {
                id: heroApps
                model: vista.showIcons && panel.selected ? panel.icons.appsFor(panel.selected.workspace) : []

                Image {
                  required property var modelData
                  width: panel.heroIconSize
                  height: panel.heroIconSize
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
              width: panel.heroWidth - heroNumber.width - Style.space(18)
              elide: Text.ElideRight
              text: {
                var ws = panel.selected ? panel.selected.workspace : null
                if (!ws || ws.toplevels.values.length === 0) return "Empty workspace"
                var ipc = ws.lastIpcObject || {}
                return ipc.lastwindowtitle ? Safe.title(ipc.lastwindowtitle) : ""
              }
              color: Util.alpha(panel.foreground, 0.7)
              font.family: panel.fontFamily
              font.pixelSize: Style.font.subtitle
            }
          }
        }
      }

      // ---------------------------------------------------------- filmstrip

      Item {
        width: strip.width
        height: strip.height + Style.space(10)
        anchors.horizontalCenter: parent.horizontalCenter

        Row {
          id: strip
          spacing: panel.thumbGap

          Repeater {
            model: vista.entries

            Column {
              id: thumb

              required property var modelData
              required property int index

              readonly property bool selected: index === vista.selectedIndex
              readonly property bool current: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData.id
              readonly property var apps: vista.showIcons ? panel.icons.appsFor(modelData.workspace) : []

              spacing: Style.space(6)
              opacity: selected ? 1 : 0.6
              Behavior on opacity { enabled: panel.duration > 0; NumberAnimation { duration: panel.duration } }

              Item {
                width: panel.thumbWidth
                height: panel.thumbHeight

                // One frame per window; the large preview carries the live view.
                WorkspacePreview {
                  anchors.fill: parent
                  workspace: thumb.modelData.workspace
                  fallbackMonitor: panel.monitor
                  active: vista.presented
                  live: false
                  showWallpaper: vista.showWallpaper
                  wallpaper: vista.wallpaperPath
                }

                // Big number over the thumbnail, shadowed to read on any preview.
                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: String(thumb.modelData.id)
                  color: panel.foreground
                  font.family: panel.fontFamily
                  font.pixelSize: Math.round(panel.thumbHeight * 0.55)
                  font.weight: Font.Bold
                  layer.enabled: true
                  layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: panel.scrim
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
                  color: panel.selectedBorder
                  visible: thumb.current
                }

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: thumb.selected ? panel.selectedBorder : panel.unselectedBorder
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onPositionChanged: function(mouse) {
                    var p = mapToItem(null, mouse.x, mouse.y)
                    var moved = panel.lastPointerX >= 0
                      && (Math.abs(p.x - panel.lastPointerX) > 2 || Math.abs(p.y - panel.lastPointerY) > 2)
                    panel.lastPointerX = p.x
                    panel.lastPointerY = p.y
                    if (moved) vista.select(thumb.index)
                  }
                  onClicked: { vista.select(thumb.index); vista.commit() }
                }
              }

              // Up to four app icons, then a count of the rest.
              Row {
                visible: vista.showIcons
                height: panel.thumbIconSize
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(4)

                Repeater {
                  model: thumb.apps.slice(0, 4)

                  Image {
                    required property var modelData
                    width: panel.thumbIconSize
                    height: panel.thumbIconSize
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
                  color: Util.alpha(panel.foreground, 0.7)
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          x: vista.selectedIndex * (panel.thumbWidth + panel.thumbGap)
          width: panel.thumbWidth
          height: Style.space(3)
          radius: height / 2
          color: panel.selectedBorder
          Behavior on x {
            enabled: panel.duration > 0
            NumberAnimation { duration: panel.duration; easing.type: Easing.OutCubic }
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
      color: Util.alpha(panel.foreground, 0.4)
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
