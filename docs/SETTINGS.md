# Settings

Everything you can change in Mouthtype, page by page, in sidebar order.

> [!NOTE]
> The Mouthtype menu has **Settings…**. <kbd>Command</kbd>+<kbd>,</kbd> opens the same window while Mouthtype is active.

The Mouthtype window has six pages in the sidebar: **Home**, **Stats**, **Dictionary**, **Transforms**, **Style** and **Appearance**. A **Settings** row at the foot of the sidebar opens the Settings modal. The modal has General, Microphone, Mac and Health pages, plus an Advanced page while the Advanced options switch in its footer is on.

**Open Mouthtype** in the menu opens Home. **Settings…** (<kbd>Command</kbd>+<kbd>,</kbd>) opens the modal on General.

## Defaults at a glance

| Setting | Default | Where |
| --- | --- | --- |
| Recording behavior | Hold to talk | Settings > General |
| Live words | Off | Settings > General |
| Quiet other audio | On (from 0.4.0; stays off if you turned it off before) | Settings > General |
| Show in Dock | While a window is open | Settings > Mac |
| Automatic update checks | On, with no prompt | Settings > Mac |
| Boost saved words | Off | Settings > Advanced |
| Code names from your editor | Off | Settings > Advanced |
| Names on screen | On (from 0.6.0; stays off if you turned it off before). Still does nothing until Boost saved words is on. Setup's Names model download turns both on | Settings > Advanced |
| Press Return after inserting | Off | Settings > Advanced |
| Override individual fonts | Off | Appearance |

## The menu

The daily menu is plain text, top to bottom. Pill style, text font, cleanup level, launch at login and the other settings aren't in the menu; they're in the Mouthtype window.

| Menu item | What it does |
| --- | --- |
| Open Mouthtype | Opens Home |
| Settings… | Opens the Settings modal on General |
| Paste Last Take, Copy Last Take | Act on the latest take, with their global shortcuts |
| Recent Takes | Lists recent takes (shown when there are takes). Stats live inside it |
| Transform Selection | Clean up, Fix grammar, Make shorter, More formal, More casual, Edit Transforms… |
| Transcribe Audio File… | Opens the Transcribe Audio File window |
| Saved Recordings | Interrupted or failed recordings |
| Check for Updates… | Checks for a new version |
| How to Use Mouthtype… | Opens the how-to window with the quick start for your current shortcut |
| About Mouthtype, Quit | Standard app items |

A few items only appear when they apply:

- Retry Speech Model and Update Available… appear above Open Mouthtype only while they apply.
- Stop and Cancel appear during hands-free recording.
- Healthy model and permission lines stay out of the menu. An attention message opens Settings > Health when something needs repair.
- Recent items copy their full text and exclude secure fields.

### Transcribe Audio File

**Transcribe Audio File…** in the menu opens the Transcribe Audio File window. Home also has a Transcribe a file button. Choose one WAV, AIFF or M4A file, then explicitly Copy or Save Text.

> [!NOTE]
> Closing the Transcribe Audio File window cancels a running transcription. The Mouthtype window can close without affecting it.

See [file transcription](FILE-TRANSCRIPTION.md) for limits and cancellation behavior.

## Home

Home lists your recent dictations grouped by day (Today, Yesterday, then dated), newest first, with the full text wrapped (nothing is cut off).

- **Copy** puts a take's text on the clipboard.
- **Recover** appears on takes whose audio is still saved and re-runs them. It is disabled while a dictation, recovery, file transcription or update is busy or the speech model isn't ready, and updates as that changes.
- Copy and Recover show on hover and on keyboard focus, and always on a saved recording with no transcript, which appears as its own row.

New takes show up as they finish without reopening the window. Takes from secure fields never show. With no takes yet the page says so.

## Stats

Stats is built from the dictation log on this Mac (nothing extra is stored). It updates as takes finish while the page is open, never shows transcript text and leaves out takes from secure fields. With no takes yet the page says so. Records no longer has its own page.

| Panel | What it shows |
| --- | --- |
| Top counter | All-time words, with words today, this week (the last seven days) and the hours you didn't have to type (the time to type the same words at 40 WPM minus your speaking time) |
| Today's tape | Every take as a needle at its time of day, taller for more words, with a hollow needle for a take whose audio is saved but has no transcript |
| Speed meter | Average speaking speed in WPM, counted only for takes of at least 5 words and 3 seconds, with the peak and a 40 WPM typist marked |
| Streak | The last 30 days. A streak is consecutive days with at least one take; the current streak carries through today until you miss a full day |
| Your day | Words by hour of the day over 30 days |
| High scores | Your fastest speaking, biggest day, longest streak and longest take, each with the day it was set. Ties go to the earliest |

## General

**General** (Settings modal) contains the dictation shortcut, Recording behavior, Language and Mouse button, then Recording sounds, Live words and Quiet other audio. **Microphone** (its own page, right after General) holds the microphone picker, Refresh inputs and the priority list. **Mac** holds Launch at login, Show in Dock and the update settings. The cleanup level lives on the Style page (Cleanup tab).

### Shortcut and recording behavior

Changing the shortcut (here or from Health) opens the recorder as a sheet on the Mouthtype window. Dictation is paused while the sheet is open. Press <kbd>Escape</kbd>, or choose Cancel, to close it without changing anything. Escape is recorded as the shortcut only while it is waiting for a key.

Choose **Hold to talk** or **Press to toggle** under Recording behavior beside the shortcut.

- Hold is the default. Keep the shortcut down while speaking and release to finish.
- Toggle starts on one press, ignores release while you speak and finishes on the next press.
- Your chosen key stays the same.
- Caps Lock keeps its existing toggle behavior in either mode; its system state may also change.
- <kbd>Escape</kbd> cancels unless Escape itself is your chosen shortcut. Use Cancel Dictation in the menu in that case.
- The pill and menu retain Stop and Cancel.

> [!NOTE]
> Changing behavior cancels an active recording instead of inserting it, and Settings says so under the row when it happens. If the listener cannot change mode, the previous mode remains saved and Settings shows the error.

### Mouse button

**Mouse button** (None, Middle, Back or Forward) sits under Recording behavior and is None by default. Pick a button and it dictates like the shortcut, in whichever recording behavior you chose.

- Hold mode: keep the button down while speaking and release to finish. A press shorter than the minimum hold is discarded.
- Toggle mode: click once to start and again to finish.
- It follows the same guards as the keyboard shortcut. A press made while a key or modifier is down is ignored, <kbd>Escape</kbd> cancels, and another key typed early in a hold discards it.
- While it is set, Mouthtype consumes only that button's presses, releases and drags, so the button no longer reaches other apps. Left and right clicks, scrolling and every other button are untouched, and with None nothing is listened to.
- It uses the Accessibility permission Mouthtype already needs for the shortcut. No new permission is requested.
- Changing the button cancels an active recording, and Settings says so under the row when it happens. If the listener cannot start, the previous choice remains saved and Settings shows the error.

### Microphone

Find this under Settings > Microphone. Choose **System Default** to follow macOS, or select a microphone for Mouthtype only. The explicit choice is remembered by its persistent device identity, so reconnecting it under a new runtime ID keeps the choice. This does not change the Mac's system input. Use Refresh inputs after connecting a device.

An unavailable saved microphone stays selected and visible. Reconnect it or explicitly select another input; Mouthtype does not silently record from a different microphone. An unreadable saved choice is retained until you explicitly choose a replacement.

Changing the setting applies to the next dictation and does not replace an active capture. Preparation coalesces one newer selection, rejects stale completion and remains unready if choices keep changing.

> [!NOTE]
> Physical device switching and Bluetooth acceptance remain unverified.

**Priority list** is an opt-in microphone choice. Order connected inputs and separately choose whether System Default may be used when none are available. The first connected listed input is chosen at the start of a take. Fixed-device choices keep their explicit missing-input behavior. See [writing tools](WRITING-TOOLS.md) for limits.

> [!NOTE]
> System Default fallback stays enabled while the microphone priority list is empty. Add an input before turning fallback off.

### Live words

**Live words** is off by default and applies to the next recording. While recording, it shows provisional recognition above the pill without replacing the meter or Stop and Cancel.

- It uses recent audio and may change or omit earlier words.
- Only the ordinary full-take result is cleaned up and inserted once after stopping.
- Cancelling discards the preview.
- Preview text is never added to history or inserted into another app.
- The current Parakeet engine reuses loaded model weights; no additional model download is required.

Preview and final recognition share one inference permit. New previews are skipped while the model is busy. A final request waits for an already-active preview to finish or acknowledge cancellation, then takes priority over new previews. Final requests retain their order and normal full-take cleanup and insertion.

Preview input is bounded to eight seconds of audio; that is not an eight-second processing deadline. The wait depends on model execution and hardware.

### Quiet other audio

**Settings > General > Quiet other audio** is on by default from 0.4.0 (it stays off if you turned it off before). Capture starts immediately.

- With recording sounds enabled, Mouthtype lets the start cue finish before muting the current default output. It waits for the decoded cue duration and checks playback for at most one additional second; a cue that remains active skips quieting for that take.
- With sounds disabled there is no cue delay.
- Ending the recording cancels any pending mute.
- On supported outputs it restores the same device after capture ends, including Stop, Escape, a discarded tap, microphone interruption and capture failure.
- Transcription and delivery do not keep other audio muted.
- Turning the option off or normally quitting Mouthtype also ends its mute.

A device that was already muted is left alone. Mouthtype never changes volume. An observed later mute or volume change gives control back to the user, so Mouthtype does not unmute that device. It checks the device UID again before restoring, rather than writing to an unrelated device that reused its numeric ID. Switching output during a recording can make the new output audible; Mouthtype only owns the original output. Outputs without a settable master mute are left unchanged and dictation continues.

> [!WARNING]
> A crash or force-quit cannot run normal restoration. Check macOS output mute if that happens.

> [!NOTE]
> Core Audio exposes property notifications, not the identity of the person or app making a change, or an atomic compare-and-set. Mouthtype registers its change listener after its own mute write and restores only if no later change was observed and the original device is still muted. Same-value writes and changes inside the registration/restore windows cannot be attributed exactly. This option does not pause media players or prevent call apps from hearing the microphone. Physical device behavior still needs coordinated testing.

### Show in Dock

**Settings > Mac > Show in Dock** chooses when Mouthtype has a Dock icon. The menu bar icon stays in every mode.

| Mode | `dockIconMode` value | Behavior |
| --- | --- | --- |
| Never | `never` | Keeps Mouthtype out of the Dock, as before. |
| While a window is open (the default, including for existing users) | `whileWindowOpen` | Shows the Dock icon while the Mouthtype window, Transcribe Audio File or Set Up Mouthtype is open, and drops it when the last one closes. A minimized window still counts. The Transform Selection panel never brings the icon up. Opening a window activates the app and keeps that window key; closing the last one doesn't take focus from the app in front. |
| Always | `always` | Keeps the icon in the Dock from launch. Clicking it with no window open opens the Mouthtype window, and the Dock menu has Open Mouthtype above the standard Quit. |

The choice applies as soon as you change it. A missing value means While a window is open. Mouthtype still launches as a menu bar app (`LSUIElement`) and switches at runtime.

### Updates

Updates are in **Mac**, and **Check for Updates…** is also in the menu.

- Automatic checks are on by default without a prompt; turn them off in Mac.
- You choose when to download and install; automatic installation is disabled.
- Checks wait while dictation, recovery or file transcription is busy.
- Scheduled offers update the menu and Settings without raising a window. Choose Review Update… in Settings (Update Available… at the top of the menu) when you are ready.
- If you agree to install while a take is running, installation waits for it and queued processing to finish, then pauses new recording and replay work until the update completes or is cancelled.
- Unconfigured source builds and diagnostic runs never start the updater.

**Mac** also holds Launch at login, which reports when macOS approval is still needed, and Show in Dock.

## Style

**Style** has five tabs: Personal messages, Work messages, Email, Other and Cleanup. Each context tab shows four tone cards (Formal, Casual, Very casual, Excited) with the same sample dictation run through the real tone rules, and the characters the tone adds are highlighted.

Tone changes capitalization and ending punctuation. Formal removes or softens swearing at Basic, Fast and Thorough (Off bypasses cleanup): exclamations, emphasis and dismissals like "fuck off" are dropped, and swear nouns and verbs become a plain word ("asshole" becomes "jerk", "fucking around" becomes "messing around"). It does not otherwise authorize paraphrasing.

Excited ends a short message with an exclamation mark instead of a full stop, and Thorough also uses exclamation marks where you sound enthusiastic (English takes only). It never adds or changes a word.

Cleanup Off bypasses the tone-detail switches, which are under Settings > Advanced. Custom tone combinations remain available. Raw file actions use your Mac's default editor and preserve unreadable originals.

### Contexts

A context is a tone plus an optional cleanup level, applied to a list of apps and websites.

| Context | Starts with |
| --- | --- |
| Personal messages | Messages, WhatsApp, Telegram, Discord and Signal (Casual) |
| Work messages | Slack, Teams, linkedin.com and teams.microsoft.com |
| Email | Mail, Outlook, mail.google.com and outlook.office.com (Formal) |
| Other | No list. It is everything not listed elsewhere, its tone is the default tone, and it can hold a cleanup level |

Built-in entries are tagged BUILT IN and yours ADDED BY YOU. Apps show their real icons, and built-in apps that aren't installed are hidden from the Counts as lists. Choose **Add an app or website** to add one, which moves it out of any other context.

**Cleanup here** overrides the cleanup level for the context (Same as everywhere, Off, Basic, Fast or Thorough). The Cleanup tab sets the global level and lists the contexts that override it. There, Fast and Thorough show their actual download/loading state. A rule can turn cleanup on for one context even when the global level is Off. A loaded cleanup model unloads after 10 minutes without use and reloads on the next take.

> [!NOTE]
> A level that needs a model that isn't installed runs as Basic, and the take records the level that actually ran. Dictations use Basic while the selected cleanup model is unavailable.

### Instructions

Free-text **Instructions** (500 characters at most) tell Thorough how text should read, for example "Keep it warm and short". The Cleanup tab holds the ones for every app and website. Each app or website row has a list icon that opens its own box, and Your own rules on the Other tab have one too. An app or website with its own instructions uses those instead. **Save** keeps them and **Clear** removes them.

Each box has a **Start from...** menu with three ready-made instructions: Slack, Keep my wording and Code comments. Choosing one puts its text in the box for you to edit. Nothing is saved until you choose **Save**, same as typing. Each was checked against the same guard that checks your own instructions.

Instructions can change tone, wording style and formatting, never meaning. Names, numbers, dates, negations and the language stay as spoken, and a result that drifts from what you said is discarded for the Basic text. Fast ignores instructions because it isn't driven by a prompt. The tone cards don't preview instructions, since that would mean loading the model on the settings page.

### Icons in the lists

Apps show their real icon from the installed app, and a letter tile when the app isn't installed. Websites show their own favicon, with a globe until it loads or when the site has none. Mouthtype fetches a site's icon once, straight from that site (its home page, then the icon it names, then `/favicon.ico`), and caches it in the Mac's Caches folder for 30 days. A failed lookup is remembered for a day. No third-party icon service is used, and there's no setting for it. Only websites you've listed or that are built in are ever contacted.

### Which rule wins

The app where recording starts determines the rule for that take. Resolution runs per field, tone and cleanup level each falling through on their own:

1. Website rules first (longest domain wins; your own rule beats a context's site, which beats a built-in site).
2. App rules (your own rule beats the app's context).
3. Other, for the cleanup level only.
4. The global default.

Instructions resolve the same way: your website rule, then your app rule, then the instructions for everywhere. Contexts don't carry instructions.

A per-app browser rule applies to that browser, and a website rule can override it for a matching HTTP/HTTPS domain and subdomains when the focused window exposes its document URL. Missing URL support falls back; document URLs are not retained. See [writing tools](WRITING-TOOLS.md).

Rules you made before the redesign keep working unchanged as explicit overrides. A tone rule shows as ADDED BY YOU under the context whose tone it matches, and a rule no context claims shows under Your own rules on the Other tab.

> [!NOTE]
> Unreadable saved rules are kept intact and cannot be overwritten from the editor; Reload retries after repair.

## Advanced

**Advanced** holds the set-once options:

- Boost saved words, Learn from my corrections, Code names from your editor and Names on screen.
- Remove fillers, Spoken commands and lists, Slash commands in coding apps (on by default; "slash research" types /research in terminals, editors and agent apps), Format numbers, Lowercase sentence starts and Drop the final full stop.
- Split long pastes per supported terminal. It starts off, applies to the chosen terminal's windows and does not identify the command-line program inside them.
- Press Return after inserting, a list of apps that get one Return after a dictation is pasted. The list starts empty, which is off everywhere. Add App… opens the app chooser, and the x on a row removes the app. Mouthtype presses Return only when the paste read-back confirms (except in terminals, below) the text landed in a text field it can read, you haven't typed or clicked since, no new recording has started, the take wasn't salvaged or recovered, and it's within two seconds. It never presses Return in password fields. Terminals (Terminal, iTerm2, Ghostty, WezTerm, Warp, kitty, Alacritty, Hyper and Orca) can't confirm a paste, so when you add one Mouthtype presses Return a moment after the paste without checking. That's still never in password fields, after a recovered take, or if you typed or clicked first. Other apps send only when Mouthtype can confirm the text landed; this hasn't been tried in live apps yet. Mouthtype turns on Electron apps' accessibility for listed apps when a recording starts, so it can confirm the paste.
- Keep finished audio for, Dictionary file, and Remap Fn.

### Boost saved words

**Boost saved words** in Settings > Advanced is off by default. It makes the speech model favour the spellings in your dictionary, so a name you saved comes out right while recognising instead of being fixed afterwards.

You can also turn it on from the Names model row on the Setup Models card, which turns on Names on screen too and uses the same download and status line.

The first time you turn it on, Mouthtype downloads an extra speech model of about 100 MB (Parakeet CTC 110M, CC BY 4.0, see the third-party notices). The line under the switch shows the download, then ready.

| Fact | Detail |
| --- | --- |
| Fallback | Until it is ready, and whenever it fails to download, load or answer within 1.5 seconds, dictation uses the ordinary transcript, so a take never fails because of it |
| Limit | Up to 200 saved spellings, starred ones first, with the heard forms you saved as aliases |
| How it works | Rescores the finished Parakeet transcript against the audio, so it is not live in the preview |
| Language | English only. The model is English, so it helps English names best, and it is skipped when a take can't be English |
| Timing | Replaced words keep the times of the words they replaced |
| History | The spellings applied to a take are saved with it in history |
| Switching off | Unloads the extra model |
| Whisper engines | Use the same switch as a prompt hint instead, with no extra download |

### Code names from your editor

**Code names from your editor** in Settings > Advanced is off by default and needs the boost above. While you dictate in VS Code, Cursor, Xcode or Terminal, iTerm2, Ghostty, kitty or WezTerm, it adds up to 40 file, folder and identifier names to the boost, after your saved spellings and inside the same 200-term limit. A name like `viewDidLoad` or `AppDelegate` is recognised instead of fixed afterwards.

Names come from three places:

- The window title (file and project).
- Identifiers around the cursor in the editor's text field (the same 300 characters before and 40 after that cleanup already reads).
- The git-tracked file names of the project in front.

Where the project comes from:

- For a terminal, the working directory of its foreground shell, read from the process list.
- For Xcode, the open document's folder.
- For VS Code and Cursor, the folder named in the title, used only when exactly one matching folder is found.

Names shorter than four letters and everyday words ("value", "item", "user") are dropped so they can't replace ordinary speech. The whole lookup has a 150 ms limit and uses whatever is ready when it ends.

Nothing is stored: the names live in memory for that one dictation, aren't logged, and are left out of the spellings saved with each take in history.

- Mouthtype doesn't read terminal screens or scrollback, other windows, or file contents.
- It doesn't switch on extra accessibility in the editor, and doesn't ask for Automation permission.
- Terminals give a folder only, never text.

> [!NOTE]
> Which of these an editor actually exposes over Accessibility varies, and is unverified for Cursor and VS Code until checked on a real install.

### Names on screen

**Names on screen** in Settings > Advanced is on by default (stays off if you turned it off) but needs the boost above, which is off by default, so it does nothing until you turn that on. In any app except a terminal, it reads up to 2000 characters of the focused text field around your cursor (1500 before, 500 after) and the window title, picks out capitalised names such as people and projects, and adds up to 30 of them to the boost for that one take. A name you were just reading in the message you're replying to comes out spelled right. The same names are also offered to project-name joining in Fast and Thorough cleanup.

- Names nearest the cursor come first, then the window title. Words that only start a sentence, everyday words ("Thanks", "Monday"), all-caps acronyms and words under four letters are dropped.
- The read has the same 150 ms limit as editor names. A field that answers late is skipped and the title alone is used, so recording never waits for it.
- Secure (password) fields and terminals are never read, and nothing is read while secure input is on.
- Slack, VS Code, Discord and other Electron apps hide their text from Accessibility until asked. With this switch on, Mouthtype sets the standard `AXManualAccessibility` flag on that app once, the first time you dictate in it. An app that doesn't support the flag ignores it. The first take in an app you've just opened may see no text yet, since the app builds it after the flag is set.
- Only Accessibility text is read: no screenshots, no other windows. Nothing is stored or logged, and the names are left out of the spellings saved with each take in history.

## Appearance

**Appearance** contains the pill style (Classic, Hi-Fi, Glass, Matrix or Minimal), Pill size, a Hi-Fi readout colour and text fonts. A live preview uses the app's actual pill drawing over a Light or Dark swatch. Glass uses the system glass material and goes solid only under Reduce Transparency or when the material is unavailable.

Delivery cards are drawn for the chosen style and scale with Pill size; Hi-Fi has its own pixel-art card. Readout colour is Amber, Cool white or Red and applies to Hi-Fi only.

### Pill size

Pill size is Automatic, Standard or Large and applies to every style.

- Automatic chooses Large when the screen the pill appears on is at least 2000 pt wide and Standard otherwise.
- Large draws everything at twice the Standard size (Hi-Fi at 292×64 pt).
- Sizes are in points, so Automatic only adjusts proportion on large screens.
- A size change applies the next time the live pill appears, and the preview shows Automatic as Standard.

### Controls by style

Only the controls that apply to the selected style show:

| Style | Controls |
| --- | --- |
| Classic, Glass, Matrix, Minimal | Pill size, Text font and Override individual fonts |
| Hi-Fi | Pill size and Readout colour |

The text-font sample shows the selected font; Hi-Fi's bitmap readouts keep their own artwork. Choose Font opens the existing native font chooser for the same global text-font preference.

### Override individual fonts

**Override individual fonts** is below the text-font choice in Appearance. It starts off. Turn it on to reveal Heading, Body and Readout family choices, each with Use base font as its default.

| Role | Applies to |
| --- | --- |
| Heading | The card header and pill messages |
| Body | Transcripts, button labels and pill details |
| Readout | Numeric text |

Role sizes, weights and tabular figures are retained. These choices affect the Classic pill and delivery cards; Hi-Fi bitmap readouts keep their artwork.

- Turning overrides off hides the controls and keeps their saved choices.
- Changing the base font preserves the overrides.
- A saved family that is unavailable uses the base font without erasing its name.
- Choose Reset fonts to defaults to clear all overrides, turn them off and restore Default. Reset stays available for saved custom choices even with overrides off; the untouched Default view keeps it hidden.
- Existing global presets and custom families keep their previous behavior; Choose Font edits the base family.
- The preview shows the active choices.

## Health

**Health** (Settings modal) holds Set Up Mouthtype, the speech and cleanup model status, permissions, the shortcut listener and the Globe key conflict. It shows:

- Actual speech-model progress and retry.
- Cleanup download/cancel and fallback state.
- Microphone and Accessibility status with System Settings links.
- Shortcut-listener health.
- The Globe conflict (Remap Fn is under Advanced). Custom shortcuts leave Fn behavior alone.

Secure Input is explained without bypassing it. File errors retain access to their raw files. Status refreshes when the menu opens, Settings activates or Refresh status is clicked; model progress and listener health update through the existing observable services.

### Paste boundary log

Mouthtype also writes a `paste boundary` entry to the existing app unified log. It contains fixed categories for the boundary source, preceding-character kind, continuation-cache eligibility and separator added, plus frontmost and focused Accessibility owner process IDs. It contains no transcript, surrounding text, window title or audio.

These entries support a future coordinated paste investigation. They do not prove delivery or change the destination, spacing policy or retry behavior.

## Dictionary

**Dictionary** (saved spellings) is a page in this window, with the same save, cancel and draft protection as before. A word groups every rule with the same written spelling, and New word and Edit word open as a sheet. Settings changes save immediately. <kbd>Command</kbd>+<kbd>W</kbd> closes the window.

Switching to another page, or closing the window, with an unsaved spelling or phrase asks first: **Keep Editing** stays on the page with your draft, **Discard** drops it. Suggestions are only looked up while Dictionary is showing.

### Import CSV

**Import CSV…** opens a sheet that previews a selected UTF-8 CSV before changing the library.

- The sheet shows a summary (new, already saved, errors) and a Row, Heard as, Write as, Result table with the first rows, every invalid row and an everyday-word warning under any row that has one, then a count of the remaining rows.
- Use a `name` header for names alone, or `heard,written` headers for exact aliases (either column order works). For example, `shawn,Sean` replaces the exact heard name with Sean.
- A name-only row saves that name as both the heard and written form; it does not guess pronunciations.
- Quoted commas, doubled quotes and multiline fields are supported.
- Files can contain up to 5,000 data rows and 1 MiB, with the same 128-character field limits as manual editing.

> [!NOTE]
> Import stays off, with the reason beside it, while any row is invalid. A conflicting alias or invalid row blocks the whole import until the CSV is fixed.

The preview shows new rows, already-saved aliases, repeated rows and errors. Identical aliases are skipped. **Import** adds only the previewed new spellings and preserves existing entries, their order and metadata. **Cancel** changes nothing. Save or cancel a dirty spelling draft first. If another writer changes the library after preview, cancel and choose the CSV again to review the current state.

### Import from another app

The **More…** menu next to Import CSV reads other dictation apps' dictionary exports into the same preview, so nothing is overwritten and nothing changes until you confirm.

- **Wispr Flow (CSV).** One word per row, or `misspelling,correction` with no header row, as Wispr Flow writes it. Empty fields are dropped. A row with more than two filled columns is an error.
- **VoiceInk (JSON).** A VoiceInk dictionary export. Each vocabulary term saves as a name, and each source phrase of a replacement saves as a heard form for that replacement.
- Superwhisper and MacWhisper are not supported. Neither publishes a documented dictionary file format.

The preview, duplicate handling and limits are the same as Import CSV. Rows already saved are skipped, and a heard phrase that is saved with a different spelling blocks the import until the file is fixed.

### Export

**More… > Export Dictionary as CSV…** saves every spelling as `heard,written`, one row per heard form, the same headers Import CSV reads. Importing that file into an empty Dictionary restores the same spellings. Starred state is not part of the CSV.

Phrases has **Export CSV…**, which saves `trigger,expansion` with multiline expansions quoted. Phrases can be exported but not imported.

### Suggestions

**Suggestions** sits at the top of Saved spellings. Mouthtype looks at your last 1,000 takes (secure-field takes are never read) and your saved spellings, and offers:

- Names it keeps mishearing.
- Lowercase names and brands.
- Split compounds like "dry doc" for Drydock.
- Saved spellings that backfire: an everyday word like "win" that rewrites to a name, or a rule that has matched nothing in a long history.

With nothing to offer it shows one line saying so. Each suggestion shows what it would save, how many times it was heard, and **Examples** with short fragments of the takes.

- **Add** saves it through the same path as New Spelling (a hazard shows **Remove** instead and deletes the rule), and a brief **Undo** appears under the list.
- **Dismiss** is remembered in `dismissed-suggestions.json` next to `dictionary.json`, and the suggestion only comes back if its count doubles.
- Weaker guesses sit under **Maybe**.
- Everyday words are never offered as something you said.
- Add and Remove are unavailable while a spelling draft has unsaved changes.

## Transforms

**Transforms** (phrases) is a page in this window, with the same save, cancel and draft protection as Dictionary. See the Dictionary section for the unsaved-draft prompt. For the Transform Selection panel, see [writing tools](WRITING-TOOLS.md).

## First-run setup

On the first ordinary launch with missing Microphone or Accessibility access, **Set Up Mouthtype** opens once. Permission requests follow the setup buttons.

- Closing it or choosing Set up later does not mark the app ready, and relaunching does not repeat the window or automatically ask for permissions.
- Existing users with both grants do not get an upgrade window.
- Reopen it from **Settings > Health > Set Up Mouthtype**. A permission attention item in the menu also opens setup.

Setup presents one focused card at a time: microphone access and preparation, Accessibility, speech model, shortcut readiness, Models, then a last card with the optional test take. It advances automatically only when the current prerequisite passes, skips components already ready and returns to an earlier prerequisite if it becomes unavailable. Denials and failures remain on their card with the appropriate settings or retry action. No permission is requested merely by advancing a card.

The **Models** card lists every model download in one place, each as the same row: name and size, one line on why you'd want it, and its state (Ready, a Download button, or a progress bar). Speech model is required and shows its status there. Fast cleanup, Thorough cleanup and Names model are optional: **Download** starts the same download as in Settings, **Cancel** stops a cleanup download, and **Continue** skips whatever you left alone. Optional downloads keep going in the background if you close setup. Names model is the Boost saved words model of about 100 MB (see Boost saved words in Settings > Advanced). Its Download button turns on Boost saved words and Names on screen, exactly as the switches in Settings > Advanced do, then shows the same progress and ready line. Nothing here touches settings unless you press that button, and the Models card shows up again each time you reopen setup.

The last card offers an optional **Try a test take**: it records about four seconds (or until you press Stop), shows the transcript and the input's peak level, and names the microphone. It never pastes, never touches the clipboard and saves no transcript or audio. If nothing came in, it says so and links to Sound settings. It won't start while a dictation is running.

Setup shows real speech download/preparation/warm-up status and a retry after failure. The speech engine's existing download is reused.

Ready to dictate requires:

- Microphone authorization and preparation.
- Accessibility.
- An active shortcut listener.
- No unresolved Fn/Globe conflict.
- A warmed speech engine.

> [!NOTE]
> Secure Input keeps setup unready. The hint follows the saved shortcut and Hold/Toggle behavior. Fast/Thorough cleanup can still be preparing; Basic is used until its model is available.

Refresh status or return from System Settings to recheck permissions. A denied permission links to its System Settings pane. An authorized microphone that could not prepare can be retried. Change shortcut opens Settings > Health for the existing shortcut, Fn remapping and keyboard controls. Diagnostic command-line probes retain their previous permission behavior and do not show or consume first-run setup.

Saved Recordings loads on demand in pages; older saved audio remains reachable.

> [!TIP]
> Use Download to repair an incomplete cleanup-model cache.

See [writing tools](WRITING-TOOLS.md) for website tone, selected-text cleanup and microphone priorities.

## For maintainers

### Checks

The ordinary `swift test --jobs 4` command includes all package test targets, including `MouthtypeSettingsUITests`. Settings rendering runs in its own test process so synchronous AppKit drawing does not block the functional cleanup tests' MainActor deadlines. It opens no visible window and changes no real preferences.

For native checks without running Core model replays, run `swift test --jobs 4 --filter 'MouthtypeMacTests|MouthtypeSettingsUITests|FnRemapKitTests'`. That includes the functional macOS tests, the offscreen render tests and the Fn tests. For only the rendering checks, run `swift test --jobs 4 --filter MouthtypeSettingsUITests`. All rendering tests run even when no PNG output directory is set.

To save the actual-view PNGs, run `MOUTHTYPE_SETTINGS_PREVIEWS=/tmp/mouthtype-settings-previews swift test --jobs 4 --filter MouthtypeSettingsUITests`. Change the output directory as needed. The settings render cases cover all six pages and the General, Microphone, Mac, Health and Advanced pages of the Settings modal in light and dark, plus the Style tabs, Large pill size and a Health attention state at 860×590pt. The Import CSV sheet adds all-valid, invalid-with-warnings and many-row cases in light and dark. Setup uses the app palette, type and buttons, and adds individual permission, microphone preparation/failure, speech loading/failure, shortcut and ready cards, including the minimum window, without invoking permission or hardware actions. Font overrides add Default, Custom, unavailable-family/minimum-width and disabled-state renders without opening the font panel. Functional settings model/menu/setup/font tests remain in `MouthtypeMacTests`.
