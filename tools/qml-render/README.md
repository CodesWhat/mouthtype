# QML render harness

Renders Omarchy plugin QML to PNG without a compositor, in light and dark, so a visual change can be looked at before anyone installs it on a real Omarchy box. The output is for eyes. There are no golden images and no pixel diffs (decision D16 in the Linux parity plan).

It stubs Quickshell and Omarchy's `qs.Commons` and `qs.Ui`, loads the real files from `tools/omarchy-plugin/`, drives them with canned state, and grabs named surfaces with `QT_QPA_PLATFORM=offscreen` and `QT_QUICK_BACKEND=software` under `qmltestrunner`.

## Run it

Needs Qt 6 declarative (`qmltestrunner`) and a font (`ttf-dejavu`) on Linux. On Arch: `pacman -S qt6-declarative qt6-svg ttf-dejavu perl`.

```
bash tools/qml-render/run.sh OUT_DIR              # every case in cases/
bash tools/qml-render/run.sh OUT_DIR panel-menu   # just one
```

From the Mac, in an Arch container on the NAS Docker testbed, with the PNGs copied back:

```
bash tools/qml-render/nas-run.sh OUT_DIR [case-name ...]
```

CI runs the `qml-render` job in `.github/workflows/linux-desktop.yml` and uploads the PNGs as the `linux-qml-renders` artifact.

Each case produces `<case>[__<target>]-light.png` and `-dark.png`, plus a `.log`. The run fails if a case does not load, a surface is missing, or the log contains a QML `ReferenceError`, `TypeError`, `Cannot assign` or `is not installed` error.

## Add a render case

Drop a file in `cases/`. The file name is the case name. The root is an `Item` that instantiates the real component from the staged plugin copy, then sets state in `setup()`.

```qml
import QtQuick
import RenderHarness
import "../plugin" as Plugin

Item {
  id: scene
  width: 420
  height: 800
  property int settleMs: 300      // optional, wait after setup() before grabbing (default 250)
  property var targets: [{ name: "popup", surface: "panel-popup" }]   // optional, default grabs the root Item

  Plugin.Panel { id: panel; opened: true }

  function setup() {              // optional, runs about 150 ms after load
    RenderRegistry.replies = { state: { running: true, state: "idle" } }
    panel.refresh()
  }
  function verifyScene(tc) {}     // optional, call tc.verify(...) for mechanical checks
}
```

- Components come from `../plugin`, which is a copy of `tools/omarchy-plugin/`. New pages under `pages/` are in that copy too.
- To feed a Panel its state, set `RenderRegistry.replies` to canned JSON keyed by the first argument after `control.py`, then call `refresh()`. This goes through the real `absorb()` path. A `Process` with no entry for its command stays silent.
- To drive the pill, call its real entry points: `service.handle(JSON.stringify({ event: "state", ... }))` or `service.showMessageFor(...)`. Set `service.prefs` inside `setup()`, not at declaration, because the prefs file load fails asynchronously and resets it.
- `Color.dark` and `RenderRegistry.dark` follow the theme the wrapper is rendering, and when `tools/omarchy-plugin/design` exists the wrapper also sets `Theme.forceDark` to match. `RenderRegistry.backdrop` is the matching background.
- A case that needs a stub the harness lacks gets that stub added under `stubs/`, in the same shape as the existing ones.

Surfaces a target can name: `panel-popup` (the `KeyboardPanel` content), `bar-button` (the `WidgetButton`), `pill-window` (the first `PanelWindow` created, which is the pill, composited on the backdrop). Every `PanelWindow` is also registered as `window-1`, `window-2` and so on in creation order. Register another one from a stub with `RenderRegistry.register("name", item)`.

## What the stubs are

- `qs.Commons` `Color` and `Style`: plausible values, not Omarchy's. Sizes are guesses at a 1x desktop. Components that hard-code colors look the same in light and dark; only code that reads `Color` changes.
- `qs.Ui` `Panel`, `KeyboardPanel`, `WidgetButton`, `PanelKeyCatcher`: plain Items. The popup renders in place, sized to its content.
- `Quickshell`, `Quickshell.Io`, `Quickshell.Hyprland`, `Quickshell.Wayland`: `PanelWindow` is an Item parked in the harness host, `Process` replays canned replies, `FileView` reads local files, `IpcHandler` does nothing.

## Known limits

- This proves layout, clipping, fonts, colors, glyph rendering and sizes. It does not prove behavior under the real shell, bar scaling, Wayland layer-shell placement, focus or input.
- The software scene graph has no shader effects. `MultiEffect` comes from `stubs/RenderEffects`, which draws its source untinted, so the bar glyph renders black in both themes instead of following `Color.foreground` or `Color.urgent`.
- `run.sh` edits a temporary copy of the plugin, never the repo: it blanks `WlrLayershell.*` attached-property lines (they need the compositor plugin), pins `import QtQuick` to 6.8 and swaps `import QtQuick.Effects` for the stand-in. Qt 6.12 ships its own QtQuick `Color` singleton that shadows `qs.Commons` `Color` for an unpinned `import QtQuick`.
- The font is whatever fontconfig finds (`DejaVu Sans` in CI). Bundled fonts are the job of the slice that adds them.
