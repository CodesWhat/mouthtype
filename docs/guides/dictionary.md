# Dictionary

The Dictionary page holds the words Mouthtype should get right: names, brands, jargon. Open it from the sidebar in the Mouthtype window.

## Saved words

Choose **New word** and fill in two things.

| Field | What it holds |
| --- | --- |
| Heard as | The form Mouthtype gets wrong. Add as many as you need, they show as chips. |
| Written | The spelling you want. |

Leave Heard as empty and Mouthtype only fixes capitalization. Rules match whole words and phrases regardless of case.

> [!TIP]
> Use a specific phrase for ambiguous everyday words. An exact rule like "geoff to Jeff" leaves "Geoffrey" alone, even through model cleanup.

The editor rejects blank or duplicate rules, keeps your other entries, and holds onto your draft if the file changes underneath you. Cleanup Off leaves words unchanged. If you ever need to repair the file by hand, **Settings → Advanced → Edit dictionary file…** opens it.

> [!WARNING]
> When a saved word is an everyday word, like "win", Mouthtype warns you, because a rule like that rewrites normal speech.

## Boost saved words

**Boost saved words** is off by default. Turn it on in **Settings → Advanced**, and the speech model favors your saved spellings while it recognizes, so a saved name comes out right instead of being fixed afterwards.

- It uses up to 200 saved words, starred ones first.
- The first time you use it Mouthtype downloads an extra speech model of about 100 MB, and dictation never waits for it.
- It's English, so it helps English names best.
- If it can't load or answer in time, you get the ordinary transcript.

## Suggestions

At the top of the page, Mouthtype looks at your last 1,000 takes and suggests words to save: names it keeps mishearing, brand names that come out lowercase, and compounds that get split like "dry doc" for Drydock. It never reads takes from secure fields and never suggests an everyday word as something you said.

Each suggestion shows what it would save, how often it was heard, and **Examples** from your takes.

- **Add** saves it. A brief **Undo** appears under the list.
- **Dismiss** hides it. It only comes back if its count doubles.
- Weaker guesses sit under **Maybe**.

Mouthtype also flags saved words that backfire, like an everyday word that rewrites to a name. Those show **Remove** instead of Add.

> [!TIP]
> You can also get a nudge while you work. When you correct a dictated word, Mouthtype may ask "Remember this spelling?". Turn that off with **Learn from my corrections** in Settings → Advanced.

## Import CSV

Choose **Import CSV…** to load many words at once. Quoted commas, doubled quotes and multiline fields work.

| Limit | Value |
| --- | --- |
| Encoding | UTF-8 |
| Data rows | Up to 5,000 |
| File size | Up to 1 MiB |
| Field length | Up to 128 characters |

There are two header styles.

```csv
name
Drydock
Priya Raman
```

A `name` header saves each name as both the heard and written form. It doesn't guess pronunciations.

```csv
heard,written
shawn,Sean
dry doc,Drydock
```

`heard,written` headers set exact aliases. Either column order works.

Before anything changes, a sheet previews the file with counts for new rows, already-saved rows and errors. It lists the first rows and every invalid row.

1. Save or cancel any unsaved draft first.
2. Choose the file and read the preview.
3. Choose **Import** to add only the new words. Your existing entries and their order stay. **Cancel** changes nothing.

Identical aliases are skipped.

> [!NOTE]
> Import stays off while any row is invalid or conflicts with an existing alias.

If something else edits your dictionary after the preview, cancel and pick the file again.

## Related

- [Cleanup and Style](cleanup-and-style.md)
- [Settings reference](../SETTINGS.md) for everything else on this page.
