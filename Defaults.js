.pragma library

// Default settings, shared by the switcher (Service.qml) and its settings
// panel (Settings.qml). A setting that is missing from shell.json uses these.
var values = {
  workspaces: 5,
  previewSize: 0.55,
  thumbnailWidth: 180,
  gap: 16,
  showIcons: true,
  showWallpaper: true,
  animations: true,
  // Workspace id -> monitor ("desc:<description>"). Unlisted workspaces
  // follow the Hyprland config.
  pins: {}
}
