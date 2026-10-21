# Editor hints

Editor hints help Mouthtype recognize code names like `viewDidLoad` or `AppDelegate` while you dictate in an editor. They're off by default.

## Turn it on

1. Turn on **Boost saved words**, which is off by default. Editor hints build on it.
2. Enable **Code names from your editor** in **Settings → Advanced**.

## What it does

Mouthtype adds up to 40 names to the boost for that one take. They come after your saved words and share the same 200-term limit.

Supported apps:

- VS Code
- Cursor
- Xcode
- Terminal, iTerm2, Ghostty, kitty and WezTerm

The names come from:

- The window title: the file and project.
- Identifiers around your cursor, the same text window cleanup reads (300 characters before the cursor and 40 after).
- The git-tracked file names of the project in front.

Where the project comes from:

| App | Project |
| --- | --- |
| Terminals | The working directory of the foreground shell |
| Xcode | The open document's folder |
| VS Code and Cursor | The folder named in the title, used only when exactly one matching folder is found |

Names shorter than four letters and everyday words like "value", "item" and "user" are dropped so they can't replace ordinary speech.

| Limit | Value |
| --- | --- |
| Lookup time | 150 ms, using whatever is ready when it ends |
| Names per take | Up to 40 |
| Shared term limit | 200 terms with your saved words |

## What it doesn't do

- It doesn't store anything. Names live in memory for that one dictation, aren't logged, and aren't saved with the take in your history.
- It doesn't read terminal screens or scrollback, other windows, or file contents.
- It doesn't turn on extra accessibility in the editor or ask for Automation permission.

## Limits

> [!WARNING]
> Which details an editor exposes over Accessibility varies, and it hasn't been verified for Cursor and VS Code on a real install. A wrong tab or a stale window title can supply another project's names. File names can be sensitive, which is why they only go to the local recognizer.

The full description is in the [settings reference](../SETTINGS.md).
