.pragma library

// Every Omarchy command Vista runs, built in one place: the notification
// that asks for the SUPER+TAB bindings (see BindCheck.qml). Each returns an
// argv array for Quickshell.execDetached / Process.command: no shell is ever
// involved, and the text is literals only.

var DEFAULT_ROOT = "/usr/share/omarchy"
var HOMEPAGE = "https://github.com/chyld/omarchy-vista"
// Both headlines start with this, so one dismiss clears either.
var HEADLINE_PREFIX = "Vista needs"

// The bin folder of the Omarchy install in use, from $OMARCHY_PATH when it is
// a plain absolute path, else the packaged location.
function bin(root) {
  var s = typeof root === "string" ? root : ""
  if (!/^\/[A-Za-z0-9._\/-]{1,200}$/.test(s) || s.indexOf("..") !== -1) s = DEFAULT_ROOT
  return s + "/bin"
}

// A critical notification for a bindStatus() problem ("missing" or
// "conflict"), replacing notification `replaceId` when it is one. -p prints
// the new id. Clicking it opens the homepage; --exec must come last.
function notify(root, status, replaceId) {
  var id = /^[1-9][0-9]{0,9}$/.test(String(replaceId)) ? String(replaceId) : "0"
  var headline = HEADLINE_PREFIX + (status === "conflict" ? " Super+Tab to itself" : " its keybindings")
  var body = "Click here to open the install steps at " + HOMEPAGE + ", then update ~/.config/hypr/bindings.lua."
  return [bin(root) + "/omarchy-notification-send", "-p", "-r", id,
          "--app-name", "Vista", "-g", "\u{f030c}", "-u", "critical", headline, body,
          "--exec", bin(root) + "/omarchy-launch-browser", HOMEPAGE]
}

// Dismisses every Vista notification (headline substring match).
function dismiss(root) {
  return [bin(root) + "/omarchy-notification-dismiss", HEADLINE_PREFIX]
}
