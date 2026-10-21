# Transforms

Transforms come in two kinds. Phrases insert text you've saved when you say a trigger. Transform Selection rewrites text you've already selected. Both are listed on the **Transforms** page in the Mouthtype window.

## Phrases

A phrase is something you say plus the exact text Mouthtype types instead. For example, say "my work email" and get your email address, alone or inside a sentence.

1. Choose **New transform**.
2. Fill in **When you say** (the trigger) and **Type instead** (the text to insert).
3. Press <kbd>Command</kbd>+<kbd>Return</kbd> to save, or <kbd>Esc</kbd> to cancel.

Matching ignores capitalization, uses whole phrases, and picks the longest match. Duplicate triggers are rejected. The library starts empty and lives in `~/Library/Application Support/Mouthtype/phrases.json`.

Each row shows its trigger, a one-line preview and a tag: TEXT, n LINES, CLIPBOARD or DATE.

### Placeholders

Two buttons in the sheet add placeholders to the text.

| Button | Adds | Becomes |
| --- | --- | --- |
| + Date | `{date}` | The date when you dictate. |
| + Clipboard | `{clipboard}` | Whatever you last copied. |

So "Meeting notes for {date}" or "Re: {clipboard}" both work.

If the file is malformed, Mouthtype keeps using the last good library and you have to repair the file before editing.

## Transform Selection

Select text in an editable field that supports Accessibility, then choose **Transform Selection** in the menu bar. The items are disabled when nothing is selected or Accessibility isn't granted.

| Item | Model |
| --- | --- |
| Clean up | None. Basic cleanup with the tone for the app you're in. |
| Fix grammar | Thorough |
| Make shorter | Thorough |
| More formal | Thorough |
| More casual | Thorough |

**Edit Transforms…** opens the Transforms page.

A small panel appears over your app without taking focus. It shows your original with removed words struck through, and a result with added or changed characters highlighted. You can edit the result.

| Button | What it does |
| --- | --- |
| Accept | Asks the app to replace your selection. The app, field, selection range and text all have to still match. Password fields and secure input are excluded. |
| Copy result | Becomes the main button when the selection changed or the app refuses the write, and an amber notice says why. |
| Retry | Reruns an AI transform. |
| Cancel | Drops it. |

Nothing pastes automatically.

> [!NOTE]
> After Accept, press <kbd>Command</kbd>+<kbd>Z</kbd> in the original app to undo, or use **Copy original**. Whether the undo restores the text depends on the app.

The AI transforms run on the Thorough model on your Mac, with one fixed instruction each and no free-form prompt. Limits:

- Without the Thorough model downloaded, they're disabled and a note says why. Download it in Settings.
- The limit is 16,000 characters.
- The text stays in memory until the panel closes and never goes into your history.

> [!WARNING]
> An accepted replacement is a request through Accessibility, not proof the text landed, so check the field.

## Related

- [Cleanup and Style](cleanup-and-style.md) covers the Thorough model download.
- [Dictionary](dictionary.md) for saved spellings.
