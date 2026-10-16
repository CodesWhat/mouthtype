# Settings

Source builds include **Settings…** in the Mouthtype menu. Command-comma opens the same window while Mouthtype is active. The current alpha.3 ZIP predates this window.

The daily menu contains Settings, Paste Last, Copy Last, Saved Recordings, a collapsed Recent Dictations submenu, Help, About and Quit. Stop and Cancel appear during hands-free recording. Healthy model and permission lines stay out of the menu; an attention message opens Diagnostics when something needs repair. Recent items copy their full text and exclude secure fields. Stats live inside Recent.

**General** contains the existing dictation shortcut, cleanup level, recording sounds and launch-at-login controls. Changing the shortcut opens the native recorder. Fast and Thorough show their actual download/loading state; dictations use Basic while the selected cleanup model is unavailable. Launch at login reports when macOS approval is still needed. Advanced delivery lets you explicitly enable split long pastes for supported terminal applications. It starts off, applies to the chosen terminal’s windows and does not identify the command-line program inside them.

**Writing** contains the default tone, app styles and the existing filler, spoken-command and number switches. Tone changes capitalization and ending punctuation. Formal does not authorize paraphrasing. Cleanup Off bypasses these settings. Advanced writing preserves learning from corrections, lowercase sentence starts, final full-stop removal and raw dictionary editing. Custom tone combinations remain available. Raw file actions use your Mac’s default editor and preserve unreadable originals.

App styles start empty. Choose **Add application…**, select an application, then choose its tone. The app where recording starts determines the rule for that take. Apps without a rule use the default tone. Choose **Use default** or remove a row to clear its override. Selecting an application that already has a rule keeps its saved tone. Browser rules apply to the browser application, not individual websites. Rules change tone, not the dictation or paste shortcut. Unreadable saved rules are kept intact and cannot be overwritten from the editor; Reload retries after repair.

**Appearance** contains Classic and Hi-Fi pill styles, Hi-Fi size and text fonts. A preview uses the app's actual pill drawing. Hi-Fi size changes apply the next time the live pill appears. The text-font sample shows the selected font; Hi-Fi's bitmap readouts keep their own artwork. Choose Font opens the existing native font chooser for the same global text-font preference.

**Diagnostics** shows actual speech-model progress and retry, cleanup download/cancel and fallback state, microphone and Accessibility status with System Settings links, shortcut-listener health, Fn remapping and Globe conflicts. Custom shortcuts leave Fn behavior alone. Secure Input is explained without bypassing it. File errors retain access to their raw files. Status refreshes when the menu opens, Settings activates or Refresh status is clicked; model progress and listener health update through the existing observable services.

The sidebar opens the existing **Saved spellings** and **Phrases** editors, preserving their save, cancel and draft protection behavior. Settings changes save immediately. Command-W closes the window.

## Checks

The ordinary `swift test --jobs 4` command includes all package test targets, including `MouthtypeSettingsUITests`. Settings rendering runs in its own test process so synchronous AppKit drawing does not block the functional cleanup tests’ MainActor deadlines. It opens no visible window and changes no real preferences.

For native checks without running Core model replays, run `swift test --jobs 4 --filter 'MouthtypeMacTests|MouthtypeSettingsUITests|FnRemapKitTests'`. That includes the functional macOS tests, both settings-render tests and the Fn tests. For only the rendering checks, run `swift test --jobs 4 --filter MouthtypeSettingsUITests`. Both rendering tests run even when no PNG output directory is set.

To save the seven actual-view PNGs, run `MOUTHTYPE_SETTINGS_PREVIEWS=/tmp/mouthtype-settings-previews swift test --jobs 4 --filter MouthtypeSettingsUITests`. Change the output directory as needed. The two render cases cover all four panes at 1000×690pt plus populated app styles, Hi-Fi Large and a Diagnostics attention state at 860×590pt. Functional settings model/menu tests remain in `MouthtypeMacTests`.
