-- Testbed override of Omarchy's monitors.lua (also silences the start-hyprland warning toast). session.sh creates one Hyprland headless output, HEADLESS-1, and
-- this pins it to 1920x1080 so VNC and screenshots are deterministic. Everything else in ~/.config/hypr is Omarchy's default.
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
hl.config({ misc = { disable_watchdog_warning = true } })
