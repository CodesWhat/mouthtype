# Cleanup and Style

Cleanup turns what you said into text you'd actually send. Style decides how formal that text sounds in each app and on each website.

Both live on the **Style** page in the Mouthtype window.

## Cleanup levels

| Level | What it does | Download |
| --- | --- | --- |
| Off | No cleanup. Spoken commands and spelling rules are bypassed too. | None |
| Basic | Fast, deterministic cleanup: filler words, spoken punctuation, whitespace and capitalization. | None |
| Fast | Local model that handles fillers, corrections and spoken technical notation while keeping your wording. Uses S1-mini by Superwhisper. | About 1.4 GB |
| Thorough | A larger local model for the same job, and the one Transform Selection uses. Uses Gemma 4 E4B. | About 5.2 GB |

Neither model rewrites what you said into a different voice. If a model's output is invalid or misses its deadline, Mouthtype delivers the Basic result instead.

The default level is Fast. Models download only when you ask:

1. Open the Cleanup tab on the Style page (or Settings → Health).
2. Choose **Download…** and confirm.
3. Watch the percentage. **Cancel download** stops it.

> [!NOTE]
> Until the level you picked has its model, takes run as Basic. That's expected, not an error.

> [!NOTE]
> Cleanup can read up to 300 characters before your cursor and 40 after it, when the app exposes them, so it can get boundary spacing and capitalization right. It never reads secure fields and doesn't read earlier chat messages.

## Tone

Tone changes capitalization and ending punctuation. Each context tab shows three cards, **Formal**, **Casual** and **Very casual**, with the same sample sentence run through the real rules, so you can see the difference before you pick.

Formal also removes or softens swearing at Basic, Fast and Thorough. Exclamations and emphasis are dropped, and swear nouns and verbs become a plain word. Tone doesn't otherwise rewrite your sentences.

## Tones per context

The Style page has four context tabs plus Cleanup.

| Context | Starts with |
| --- | --- |
| Personal messages | Messages, WhatsApp, Telegram, Discord and Signal, set to Casual |
| Work messages | Slack, Teams, linkedin.com and teams.microsoft.com |
| Email | Mail, Outlook, mail.google.com and outlook.office.com, set to Formal |
| Other | Everything not listed elsewhere. Its tone is your default |

Entries that ship with the app are tagged BUILT IN. Yours are tagged ADDED BY YOU.

## Add an app or website rule

On a context tab, choose **Add an app or website**. Adding one moves it out of any other context. For a website, enter a plain ASCII domain like `slack.com`. A domain rule also matches its subdomains.

Each context can also set **Cleanup here**: Same as everywhere, Off, Basic, Fast or Thorough. That means cleanup can be on for one app while it's off everywhere else. A level whose model isn't installed runs as Basic.

The Cleanup tab sets the global level and lists the contexts that override it.

## Which rule wins

The app where recording starts decides the rule for that take. Tone and cleanup level each fall through on their own, in this order:

1. Website rules, longest matching domain first. Your own rule beats a context's site, which beats a built-in one.
2. App rules. Your own rule beats the app's context.
3. Other, for the cleanup level only.
4. The global default.

> [!NOTE]
> Website rules work in Safari, Chrome, Edge and Brave when the focused window exposes its page URL through macOS Accessibility. If it doesn't, Mouthtype falls back to the app rule. Only HTTP and HTTPS pages count, password fields are excluded, and the URL isn't stored or logged. Mouthtype doesn't scrape the address bar or ask for extra browser permissions.

More detail and the limits are in the [writing tools reference](../WRITING-TOOLS.md).

## Related

- [Dictionary](dictionary.md) fixes names and spellings.
- [Transforms](transforms.md) rewrites text you've already written.
