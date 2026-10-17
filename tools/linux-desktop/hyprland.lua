-- Hyprland >= 0.55. Inspect existing bindings before adding these examples.
-- No locked flag: recording and typing must not be enabled on a lock screen.
hl.bind("F9", hl.dsp.exec_cmd("mouthtype-linux start"))
hl.bind("F9", hl.dsp.exec_cmd("mouthtype-linux stop"), { release = true })
hl.bind("F10", hl.dsp.exec_cmd("mouthtype-linux toggle"))
hl.bind("F11", hl.dsp.exec_cmd("mouthtype-linux cancel"))
