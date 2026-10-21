-- Hyprland >= 0.55. Inspect existing bindings before adding these examples.
-- No locked flag: recording and typing must not be enabled on a lock screen.
hl.bind("F10", hl.dsp.exec_cmd("mouthtype-linux toggle"))
hl.bind("F11", hl.dsp.exec_cmd("mouthtype-linux cancel"))

-- Hold-to-talk is not offered as a bare start/stop pair. Press and release launch two independent
-- processes with no ordering between them, so a quick tap or a rapid repeat can leave a recording running.
-- With the Omarchy plugin installed, use its Change Dictation Shortcut menu, or bind its ordered wrapper:
-- hl.bind("F9", hl.dsp.exec_cmd("~/.config/omarchy/plugins/dstahl.mouthtype/control.py start"))
-- hl.bind("F9", hl.dsp.exec_cmd("~/.config/omarchy/plugins/dstahl.mouthtype/control.py stop"), { release = true })

-- Transform Selection panel (Omarchy plugin installed). Captures the selection, then opens the floating card.
-- hl.bind("SUPER + SHIFT + T", hl.dsp.exec_cmd("~/.config/omarchy/plugins/dstahl.mouthtype/control.py transform-open"))
