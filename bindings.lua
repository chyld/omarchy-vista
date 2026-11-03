-- Vista keybindings. Add to ~/.config/hypr/bindings.lua.
--
-- Hold SUPER, tap TAB / SHIFT+TAB to cycle, release SUPER to switch.
-- Replaces Omarchy's SUPER+TAB (next workspace) and SUPER+SHIFT+TAB
-- (previous workspace).
--
-- The binds are applied again once Hyprland has read the whole config
-- (config.reloaded fires at startup and after every reload), so they win over
-- anything loaded after this file that binds the same keys, such as
-- hyprmoncfg's generated hyprmoncfg-monitors.lua, which hyprland.lua loads last.
local function vista_bind()
  hl.unbind("SUPER + TAB")
  hl.unbind("SUPER + SHIFT + TAB")
  o.bind("SUPER + TAB", "Vista: next workspace", hl.dsp.global("chyld-vista:next"), { repeating = true })
  o.bind("SUPER + SHIFT + TAB", "Vista: previous workspace", hl.dsp.global("chyld-vista:prev"), { repeating = true })
end
vista_bind()
hl.on("config.reloaded", vista_bind)
hl.layer_rule({ match = { namespace = "chyld-vista" }, no_anim = true })
