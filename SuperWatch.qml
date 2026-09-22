import QtQuick
import Quickshell.Io
import "Hypr.js" as Hypr

// Answers "is SUPER still held?" by asking the compositor, and emits
// `released` once it is not. This covers a tap released before the overlay
// gets keyboard focus, and any release the overlay never receives.
//
// One query at a time, every 50 ms, for at most 30 s per start; the reply is
// read in chunks under a 512-byte budget with a 1 s deadline. Only a clear
// "false" counts as released: a failed or unreadable reply is asked again.
Item {
  id: watch

  signal released()

  property real startedAt: 0

  function start() {
    watch.startedAt = Date.now()
    poll.restart()
  }

  function stop() {
    poll.stop()
  }

  Timer {
    id: poll
    interval: 50
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (Date.now() - watch.startedAt > 30000) { stop(); return }
      if (!query.running) query.running = true
    }
  }

  Process {
    id: query
    property string buf: ""
    command: Hypr.superIsDown()
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (query.buf.length + chunk.length > 512) { query.buf = ""; query.signal(15); return }
        query.buf += chunk
      }
    }
    onStarted: { buf = ""; deadline.restart() }
    onExited: function(code) {
      deadline.stop()
      var reply = buf.trim()
      buf = ""
      // hyprctl eval reports the value through error(), so the answer is the
      // end of the reply whatever the exit code.
      if (poll.running && /false$/.test(reply)) { poll.stop(); watch.released() }
    }
  }

  Timer { id: deadline; interval: 1000; onTriggered: query.signal(9) }

  // Stop an in-flight query when the plugin unloads.
  Component.onDestruction: { poll.stop(); if (query.running) query.signal(9) }
}
