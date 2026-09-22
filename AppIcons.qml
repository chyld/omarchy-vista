import QtQuick
import Quickshell
import "Safe.js" as Safe

// Resolves the icons of the apps on a workspace.
//
// Window classes are set by the application, so only plain names are looked
// up: a desktop entry by id, then by StartupWMClass, then the icon theme. A
// desktop entry's Icon= may be an absolute path, which is accepted only inside
// the system and user icon folders. Results are cached for the life of the
// shell, up to 200 classes.
Item {
  id: icons

  readonly property string home: Quickshell.env("HOME")

  // Read inside bindings, so it is mutated in place and never reassigned: a
  // notifying property here would be a binding loop.
  readonly property var cache: ({ map: Object.create(null), size: 0 })

  // One entry per app on the workspace, most recently focused first, at most 16.
  function appsFor(workspace) {
    if (!workspace) return []
    var toplevels = workspace.toplevels.values.slice(0, 64)
    toplevels.sort(function(a, b) { return focusOrder(a) - focusOrder(b) })
    var seen = Object.create(null)
    var list = []
    for (var i = 0; i < toplevels.length && list.length < 16; i++) {
      var cls = appClass(toplevels[i])
      if (!cls || seen[cls]) continue
      seen[cls] = true
      list.push({ name: cls, icon: iconFor(cls) })
    }
    return list
  }

  function focusOrder(toplevel) {
    var ipc = toplevel.lastIpcObject
    return ipc && ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 99
  }

  function appClass(toplevel) {
    var ipc = toplevel.lastIpcObject || {}
    if (ipc.class) return Safe.appClass(ipc.class)
    return toplevel.wayland && toplevel.wayland.appId ? Safe.appClass(toplevel.wayland.appId) : ""
  }

  function iconFor(cls) {
    if (cache.map[cls] !== undefined) return cache.map[cls]
    if (cache.size >= 200) { cache.map = Object.create(null); cache.size = 0 }
    var lower = cls.toLowerCase()
    var path = ""
    var ids = [cls, lower, lower.split(".").pop()]
    for (var i = 0; i < ids.length && !path; i++) {
      var entry = DesktopEntries.byId(ids[i])
      if (entry && entry.icon) path = source(entry.icon)
    }
    var apps = DesktopEntries.applications.values
    for (var j = 0; j < apps.length && !path; j++) {
      if (apps[j].startupClass && apps[j].startupClass.toLowerCase() === lower && apps[j].icon)
        path = source(apps[j].icon)
    }
    if (!path) path = Quickshell.iconPath(lower, true)
    if (!path) path = Quickshell.iconPath("application-x-executable", true)
    cache.map[cls] = path
    cache.size++
    return path
  }

  function source(icon) {
    var s = String(icon || "")
    if (s.length === 0 || s.length > 512 || /[\u0000-\u001f]/.test(s)) return ""
    if (s.charAt(0) !== "/") return /^[A-Za-z0-9._+-]{1,128}$/.test(s) ? Quickshell.iconPath(s, true) : ""
    if (s.indexOf("/../") !== -1 || s.indexOf("/./") !== -1 || !/\.(png|svg)$/i.test(s)) return ""
    var roots = ["/usr/share/icons/", "/usr/share/pixmaps/",
                 home + "/.local/share/icons/", home + "/.local/share/applications/icons/"]
    for (var i = 0; i < roots.length; i++) if (s.indexOf(roots[i]) === 0) return Quickshell.iconPath(s, true)
    return ""
  }
}
