-- Vista keybindings. Add to ~/.config/hypr/bindings.lua *after*
-- any other plugin that binds SUPER+TAB (e.g. vbrosseau.alttab), so these win.
--
-- Hold SUPER, tap TAB / SHIFT+TAB to cycle, release SUPER to switch.
-- Replaces Omarchy's SUPER+TAB (next workspace) and SUPER+SHIFT+TAB
-- (previous workspace).
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
o.bind("SUPER + TAB", "Vista: next workspace", hl.dsp.global("chyld-vista:next"), { repeating = true })
o.bind("SUPER + SHIFT + TAB", "Vista: previous workspace", hl.dsp.global("chyld-vista:prev"), { repeating = true })
hl.layer_rule({ match = { namespace = "chyld-vista" }, no_anim = true })
