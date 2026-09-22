import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Hypr.js" as Hypr
import "Omarchy.js" as Omarchy

// Checks that SUPER+TAB and SUPER+SHIFT+TAB reach Vista, and says so with a
// desktop notification when they do not. Without the bindings from
// bindings.lua the switcher can never open, and nothing else would tell you.
//
// Checked a few seconds after load and after every Hyprland config reload
// (Hyprland reloads whenever one of its files is saved). Every check that
// finds a problem notifies, replacing Vista's previous notification rather
// than stacking a new one. The notification is critical, so it stays until
// clicked or dismissed and survives a shell restart; one left from an
// earlier session is dismissed before the first new one, and any Vista
// notification is dismissed once the bindings are right or Vista unloads.
// The bind list is read in chunks under a 1 MiB budget with a 3 s deadline;
// an unreadable reply changes nothing. Sending and dismissing each have a
// 5 s deadline.
Item {
  id: check

  readonly property string omarchyRoot: String(Quickshell.env("OMARCHY_PATH") || "")

  // The id of Vista's notification from this session, so the next one
  // replaces it; "0" until one is sent.
  property string notificationId: "0"
  // Whether a Vista notification may be on screen. True at start: a critical
  // one from an earlier session is restored when the shell starts.
  property bool mayBeShowing: true
  // The notification waiting for the dismiss before it.
  property var pendingSend: null
  // The newest check result that arrived while a notification command ran.
  property string pendingStatus: ""
  // A check was asked for while one was running: run again after it.
  property bool rerun: false

  readonly property bool busy: sender.running || dismisser.running

  function run() {
    if (query.running) check.rerun = true
    else query.running = true
  }

  function report(status) {
    if (check.busy) { check.pendingStatus = status; return }
    if (status === "ok") {
      if (check.mayBeShowing) check.dismiss(null)
      return
    }
    var argv = Omarchy.notify(check.omarchyRoot, status, check.notificationId)
    // Nothing from this session to replace: clear any left from before.
    if (check.notificationId === "0" && check.mayBeShowing) check.dismiss(argv)
    else check.send(argv)
  }

  // Apply a result held back while a command ran.
  function flush() {
    if (check.busy || check.pendingStatus === "") return
    var status = check.pendingStatus
    check.pendingStatus = ""
    check.report(status)
  }

  function send(argv) {
    sender.command = argv
    sender.running = true
    check.mayBeShowing = true
  }

  // Dismiss every Vista notification, then send `next` if given.
  function dismiss(next) {
    check.pendingSend = next
    dismisser.command = Omarchy.dismiss(check.omarchyRoot)
    dismisser.running = true
  }

  Process {
    id: dismisser
    onStarted: dismissDeadline.restart()
    onExited: function(code) {
      dismissDeadline.stop()
      // A failed or killed dismiss may have left the notification up.
      if (code === 0) {
        check.mayBeShowing = false
        check.notificationId = "0"
      }
      var next = check.pendingSend
      check.pendingSend = null
      if (next) check.send(next)
      else Qt.callLater(check.flush)
    }
  }

  // Sends the notification and keeps the id it prints (-p) for the next one.
  Process {
    id: sender
    property string buf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { if (sender.buf.length < 64) sender.buf += chunk }
    }
    onStarted: { buf = ""; sendDeadline.restart() }
    onExited: function(code) {
      sendDeadline.stop()
      var id = buf.trim()
      buf = ""
      if (code === 0 && /^[1-9][0-9]{0,9}$/.test(id)) check.notificationId = id
      Qt.callLater(check.flush)
    }
  }

  // Both commands talk to the shell over D-Bus and finish in well under a
  // second; a hung one is killed so Vista never stays busy.
  Timer { id: sendDeadline; interval: 5000; onTriggered: sender.signal(9) }
  Timer { id: dismissDeadline; interval: 5000; onTriggered: dismisser.signal(9) }

  // The shell and its notification service start alongside this plugin.
  Timer { id: startDelay; interval: 3000; running: true; onTriggered: check.run() }

  // Hyprland registers the new binds just after it reports the reload.
  Timer { id: reloadSettle; interval: 1000; onTriggered: check.run() }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") reloadSettle.restart()
    }
  }

  Process {
    id: query
    property string buf: ""
    property bool overflow: false
    command: Hypr.listBinds()
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (query.overflow) return
        query.buf += chunk
        if (query.buf.length > 1048576) { query.overflow = true; query.buf = ""; query.signal(15) }
      }
    }
    onStarted: { buf = ""; overflow = false; deadline.restart() }
    onExited: function(code) {
      deadline.stop()
      var json = overflow || code !== 0 ? "" : buf
      buf = ""
      // A reload came in while this ran: its answer may predate the new
      // binds, so ask again instead of using it.
      if (check.rerun) { check.rerun = false; Qt.callLater(check.run); return }
      var binds = null
      try { binds = JSON.parse(json) } catch (e) { return }
      check.report(Hypr.bindStatus(binds))
    }
  }

  Timer { id: deadline; interval: 3000; onTriggered: query.signal(9) }

  // Stop in-flight commands when the plugin unloads, and take down the
  // notification: it is critical and would otherwise outlive Vista.
  Component.onDestruction: {
    if (query.running) query.signal(9)
    if (sender.running) sender.signal(9)
    if (dismisser.running) dismisser.signal(9)
    if (check.mayBeShowing) Quickshell.execDetached(Omarchy.dismiss(check.omarchyRoot))
  }
}
