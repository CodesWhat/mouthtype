# Getting started

Install Mouthtype, give it the two permissions it needs, and dictate your first sentence.

## What you need

An Apple Silicon Mac running macOS 26 or later. That's the only supported setup for the current release, 0.10.0.

## Install

1. Download the DMG from [mouthtype.app/download](https://mouthtype.app/download) and open it.
2. Drag Mouthtype.app into Applications. If an older Mouthtype is running, quit it first.
3. Open Mouthtype from Applications.

Or install it with Homebrew from the CodesWhat tap:

```sh
brew install --cask codeswhat/tap/mouthtype
```

It installs the same signed, notarized build. Mouthtype updates itself from the menu, so you don't need `brew upgrade`. `brew uninstall --zap --cask mouthtype` also removes its settings and history.

> [!NOTE]
> The app is Developer ID signed and notarized. If macOS rejects it anyway, note the exact message. Don't turn off Gatekeeper.

> [!NOTE]
> If you're on one of the alpha builds (1 through 3), you need this download once. Those builds have no updater. From here on, **Check for Updates…** in the menu does it.

## Allow Microphone and Accessibility

Mouthtype needs both.

| Permission | What it's for |
| --- | --- |
| Microphone | How it hears you. |
| Accessibility | How the shortcut works and how text gets into the app you're using. |

On the first launch with either one missing, **Set Up Mouthtype** opens and walks you through it one card at a time.

1. Allow Microphone when macOS asks.
2. Turn Mouthtype on under System Settings → Privacy & Security → Accessibility.
3. Come back to the app.

Each card moves on once its step is done, and Mouthtype checks Accessibility about once a second, so you don't need to relaunch.

> [!TIP]
> If you close setup, it doesn't nag again on the next launch. Reopen it any time from **Settings → Health → Set Up Mouthtype**.

## Wait for the speech model

The speech model and a small speech detector download on first launch. Setup shows the progress. Downloads need internet access. After that, recognition runs on your Mac.

Basic cleanup works with no extra download. The optional Fast and Thorough cleanup models download only when you ask for them. Until the one you picked is ready, Mouthtype uses Basic. See [Cleanup and Style](cleanup-and-style.md).

| Model | Download |
| --- | --- |
| Basic | None |
| Fast | About 1.4 GB |
| Thorough | About 5.2 GB |

## Your first dictation

1. Click into a text field. A blank TextEdit document is a good first target.
2. Hold <kbd>Fn</kbd> and say a sentence.
3. Let go. Clean text appears where your cursor is.

Dictate a second sentence without clicking or typing in between. You should get one insertion per take, with a space between them.

If Fn opens the emoji picker or nothing happens, see [Troubleshooting](../TROUBLESHOOTING.md). Keyboards without a Fn or Globe key can pick another shortcut under **Settings → General**.

## Where next

- [Dictating](dictating.md) covers hands-free mode, shortcuts and recovery.
- [Dictionary](dictionary.md) teaches Mouthtype the names it gets wrong.
- The [install notes](../READ-ME.md) have the full release notes for 0.9.1 and earlier.
