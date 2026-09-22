import QtQuick
import qs.Commons
import qs.Ui
import Quickshell.Hyprland
import "Defaults.js" as Defaults
import "Safe.js" as Safe

// Bar icon for Vista. Clicking it opens a settings popup;
// every change is written straight to this widget's entry in shell.json,
// which the switcher watches, so it applies immediately.
Panel {
  id: root
  moduleName: "chyld.vista"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function value(key) {
    return root.setting(key, Defaults.values[key])
  }

  // The popup updates at once; the save to shell.json waits until the
  // control has finished animating, because the write makes the shell
  // refresh the bar and would stall the animation mid-way.
  function set(key, v) {
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = v
    root.settings = next
    saveTimer.restart()
  }

  Timer {
    id: saveTimer
    interval: 200
    onTriggered: if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ------------------------------------------------------------ monitor pins

  readonly property int workspaceCount: Math.max(1, Math.min(Safe.MAX_WORKSPACE, Number(root.value("workspaces")) || 1))
  readonly property var pins: Safe.pins(root.value("pins"))

  // Connected monitors, left to right, keyed by description so a pin
  // survives the monitor moving to another port.
  readonly property var monitors: {
    var list = []
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length && list.length < 8; i++) {
      var m = values[i]
      var ipc = m.lastIpcObject || {}
      var name = String(m.name || "")
      var key = ipc.description ? Safe.monitorKey("desc:" + ipc.description) : Safe.monitorKey(name)
      if (!key) continue
      // The model name comes from the monitor's EDID: keep it plain and short.
      var label = name.indexOf("eDP") === 0 ? "Laptop" : Safe.plain(ipc.model || name, 24)
      list.push({ key: key, label: label || Safe.plain(name, 24), x: Number(m.x) || 0 })
    }
    list.sort(function(a, b) { return a.x - b.x })
    return list
  }

  // Clicking a workspace's chip on a monitor pins it there; clicking the
  // pinned chip again unpins it.
  function togglePin(workspaceId, monitorKey) {
    var id = Safe.workspaceId(workspaceId)
    var key = Safe.monitorKey(monitorKey)
    if (!id || !key) return
    var next = {}
    for (var k in root.pins) next[k] = root.pins[k]
    if (next[id] === key) delete next[id]
    else next[id] = key
    root.set("pins", next)
  }

  onOpenedChanged: if (opened) Hyprland.refreshMonitors()

  // Hand the current settings to this plugin's own switcher service, so it
  // follows every change at once (see Service.qml, pushedSettings).
  function pushToService() {
    var shell = root.bar ? root.bar.shell : null
    var service = shell && typeof shell.serviceFor === "function" ? shell.serviceFor(root.moduleName) : null
    if (service && "pushedSettings" in service) service.pushedSettings = root.settings
  }

  onSettingsChanged: pushToService()
  onBarChanged: pushToService()

  function reset() {
    root.settings = ({})
    saveTimer.restart()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Custom vector mark (Logo.qml).
    iconComponent: Component {
      Logo { color: button.foreground }
    }
    tooltipText: root.opened ? "" : "Vista settings"
    onPressed: function(b) { root.toggle() }
  }

  // ------------------------------------------------------------ popup parts

  // A titled group of settings on a faint raised surface.
  component Card: BorderSurface {
    id: card
    default property alias body: box.data
    property string title: ""
    property color fg: Color.foreground

    width: parent ? parent.width : 0
    implicitHeight: box.implicitHeight + Style.space(28)
    radius: Style.cornerRadius
    color: Util.alpha(fg, 0.035)
    borderSpec: Border.flat(Util.alpha(fg, 0.10), 1)

    Column {
      id: box
      x: Style.space(14)
      y: Style.space(14)
      width: card.width - Style.space(28)
      spacing: Style.space(12)

      Text {
        visible: card.title !== ""
        textFormat: Text.PlainText
        text: card.title.toUpperCase()
        color: Util.alpha(card.fg, 0.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.4
      }
    }
  }

  // Label on the left, its control on the right.
  component SettingRow: Item {
    id: row
    default property alias control: slot.data
    property string label: ""
    property string hint: ""
    property color fg: Color.foreground

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labels.implicitHeight, slot.height)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: slot.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.label
        elide: Text.ElideRight
        color: row.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        visible: row.hint !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: row.hint
        wrapMode: Text.WordWrap
        color: Util.alpha(row.fg, 0.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Item {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------------------------------------------------------- header

        Row {
          spacing: Style.space(14)

          Rectangle {
            width: Style.space(52)
            height: width
            radius: Math.max(Style.cornerRadius, Style.space(4))
            color: Util.alpha(Color.accent, 0.12)
            border.width: 1
            border.color: Util.alpha(Color.accent, 0.35)

            Logo {
              anchors.centerIn: parent
              width: Style.space(32)
              height: width
              color: root.barForeground
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              textFormat: Text.PlainText
              text: "Vista"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: "HOLD SUPER · TAP TAB · RELEASE"
              color: Util.alpha(root.barForeground, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
        }

        // ---------------------------------------------------------- layout

        Card {
          title: "Layout"
          fg: root.barForeground

          // A to-scale sketch of the switcher on a 16:9 screen: the large
          // preview and the filmstrip follow the settings below.
          Rectangle {
            id: sketch
            readonly property real screenW: Style.space(208)
            readonly property int count: root.workspaceCount
            readonly property real heroW: screenW * Number(root.value("previewSize"))
            readonly property real tileW: {
              var preferred = screenW * Number(root.value("thumbnailWidth")) / 1920
              var fit = (screenW - Style.space(12) - (count - 1) * Style.space(3)) / count
              return Math.max(Style.space(4), Math.min(preferred, fit))
            }

            anchors.horizontalCenter: parent.horizontalCenter
            width: screenW
            height: Math.round(screenW * 9 / 16)
            radius: Math.max(2, Style.cornerRadius / 2)
            color: Util.alpha(Color.background, 0.6)
            border.width: 1
            border.color: Util.alpha(root.barForeground, 0.18)

            Column {
              anchors.centerIn: parent
              spacing: Style.space(6)

              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: sketch.heroW
                height: width * 9 / 16
                radius: Math.max(1, Style.cornerRadius / 3)
                color: Util.alpha(root.barForeground, 0.10)
                border.width: 1
                border.color: Color.accent
                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(3)

                Repeater {
                  model: sketch.count

                  Rectangle {
                    required property int index
                    width: sketch.tileW
                    height: width * 9 / 16
                    radius: 1
                    color: index === 1 ? Color.accent : Util.alpha(root.barForeground, 0.22)
                    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                  }
                }
              }
            }
          }

          Repeater {
            model: [
              { key: "workspaces", label: "Workspaces", options: [
                { value: "3", label: "3" }, { value: "5", label: "5" },
                { value: "8", label: "8" }, { value: "10", label: "10" }] },
              { key: "previewSize", label: "Preview", options: [
                { value: "0.45", label: "S" }, { value: "0.55", label: "M" },
                { value: "0.7", label: "L" }] },
              { key: "thumbnailWidth", label: "Thumbnails", options: [
                { value: "140", label: "S" }, { value: "180", label: "M" },
                { value: "240", label: "L" }] }
            ]

            SettingRow {
              required property var modelData
              label: modelData.label
              fg: root.barForeground

              ButtonGroup {
                options: modelData.options
                value: String(root.value(modelData.key))
                foreground: root.barForeground
                onChanged: function(v) { root.set(modelData.key, Number(v)) }
              }
            }
          }
        }

        // ---------------------------------------------------------- monitors

        Card {
          title: "Pin to monitor"
          fg: root.barForeground

          Repeater {
            model: root.monitors

            Column {
              id: monitorRow
              required property var modelData
              width: parent.width
              spacing: Style.space(6)

              Row {
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: monitorRow.modelData.label === "Laptop" ? "\u{f0322}" : "\u{f0379}"   // nf-md-laptop / monitor
                  color: Util.alpha(root.barForeground, 0.7)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: monitorRow.modelData.label
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Row {
                id: chips
                spacing: Style.space(4)
                // Chips share the row, never wider than a comfortable square.
                readonly property real chipWidth: Math.min(Style.space(32),
                  Math.floor((monitorRow.width - (root.workspaceCount - 1) * spacing) / root.workspaceCount))

                Repeater {
                  model: root.workspaceCount

                  Button {
                    required property int index
                    readonly property string workspaceId: String(index + 1)
                    width: chips.chipWidth
                    text: workspaceId
                    bordered: true
                    selected: root.pins[workspaceId] === monitorRow.modelData.key
                    foreground: root.barForeground
                    // Host-rendered tooltip: the monitor label is EDID data, so strip it again.
                    tooltipText: Safe.plain(selected ? "Unpin workspace " + workspaceId
                      : "Pin workspace " + workspaceId + " to " + monitorRow.modelData.label, 64)
                    onClicked: root.togglePin(workspaceId, monitorRow.modelData.key)
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Click to pin, click again to unpin. Unpinned workspaces follow your Hyprland config."
            color: Util.alpha(root.barForeground, 0.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------------------------------------------------------- appearance

        Card {
          title: "Appearance"
          fg: root.barForeground

          Repeater {
            model: [
              { key: "showIcons", label: "App icons", hint: "The apps on each workspace" },
              { key: "showWallpaper", label: "Wallpaper", hint: "Behind every preview" },
              { key: "animations", label: "Animations", hint: "Fades and the sliding bar" }
            ]

            SettingRow {
              required property var modelData
              label: modelData.label
              hint: modelData.hint
              fg: root.barForeground

              ToggleSwitch {
                cursorRing: false
                checked: root.value(modelData.key) === true
                foreground: root.barForeground
                onToggled: root.set(modelData.key, !checked)
              }
            }
          }
        }

        // ---------------------------------------------------------- footer

        Item {
          width: parent.width
          height: resetButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Changes apply instantly"
            color: Util.alpha(root.barForeground, 0.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            id: resetButton
            anchors.right: parent.right
            text: "Reset to defaults"
            foreground: root.barForeground
            bordered: true
            onClicked: root.reset()
          }
        }
      }
    }
  }
}
