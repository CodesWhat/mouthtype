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

Tone changes capitalization and ending punctuation. Each context tab shows four cards, **Formal**, **Casual**, **Very casual** and **Excited**, with the same sample sentence run through the real rules, so you can see the difference before you pick. The characters a tone adds are highlighted.

**Excited** ends a short message with an exclamation mark instead of a full stop, and Thorough also uses exclamation marks where you sound enthusiastic (English takes only). It never adds, drops or changes a word. Questions keep their question mark.

Formal also removes or softens swearing at Basic, Fast and Thorough. Exclamations and emphasis are dropped, and swear nouns and verbs become a plain word. Tone doesn't otherwise rewrite your sentences.

## Tones per context

The Style page has four context tabs plus Cleanup.

| Context | Starts with |
| --- | --- |
| Personal messages | Messages, WhatsApp, Telegram, Discord and Signal, set to Casual |
| Work messages | Slack, Teams, linkedin.com and teams.microsoft.com |
| Email | Mail, Outlook, mail.google.com and outlook.office.com, set to Formal |
| Other | Everything not listed elsewhere. Its tone is your default |

Entries that ship with the app are tagged BUILT IN. Yours are tagged ADDED BY YOU. Apps show their real icons, and built-in apps that aren't installed are hidden from the Counts as lists.

## Add an app or website rule

On a context tab, choose **Add an app or website**. Adding one moves it out of any other context. For a website, enter a plain ASCII domain like `slack.com`. A domain rule also matches its subdomains.

Each context can also set **Cleanup here**: Same as everywhere, Off, Basic, Fast or Thorough. That means cleanup can be on for one app while it's off everywhere else. A level whose model isn't installed runs as Basic. A loaded cleanup model unloads after 10 minutes without use and reloads on the next take.

The Cleanup tab sets the global level and lists the contexts that override it.

## Instructions

Instructions are a few sentences of your own that tell Thorough how the text should read, for example "Keep it warm and short" or "Put action items in a bullet list". You can set them in two places:

- **Everywhere.** On the Cleanup tab, under **Instructions**.
- **One app or website.** Click the list icon on its row on a context tab, or on a row under Your own rules on the Other tab, and write them in the box that opens. An app or website with its own instructions uses those instead of the ones for everywhere.

Not sure what to write? Use the **Start from...** menu beside the box. It offers Slack (short and casual, no greeting or sign-off), Keep my wording (only punctuation, capitalization and grammar) and Code comments (terse, no trailing period on a one-line comment). Choosing one fills the box with its text, which you can edit. Nothing is saved until you choose **Save**.

Instructions are limited to 500 characters. Choose **Save** to keep them and **Clear** to remove them. A rule that only holds instructions is fine, and clearing them removes a rule that sets nothing else.

Instructions only change tone, wording style and formatting. Thorough is still told to keep what you said: names, numbers, dates, negations and the language stay as spoken. After the model answers, the same checks Thorough always runs compare its text with yours. If the result changed a name or number, dropped a "not", was translated, or answered the dictation instead of cleaning it, it's thrown away and you get the Basic text. So an instruction like "round every number" or "translate to Spanish" can't change what you said.

> [!NOTE]
> Fast ignores instructions. It isn't driven by a prompt, so only Thorough reads them. The sample cards on the Style page show tone only, because showing the effect of instructions would mean loading the model on the settings page.

## Which rule wins

The app where recording starts decides the rule for that take. Tone and cleanup level each fall through on their own, in this order:

1. Website rules, longest matching domain first. Your own rule beats a context's site, which beats a built-in one.
2. App rules. Your own rule beats the app's context.
3. Other, for the cleanup level only.
4. The global default.

Instructions follow the same order for your own website and app rules, then fall back to the instructions for everywhere. Contexts don't carry instructions.

> [!NOTE]
> Website rules work in Safari, Chrome, Edge and Brave when the focused window exposes its page URL through macOS Accessibility. If it doesn't, Mouthtype falls back to the app rule. Only HTTP and HTTPS pages count, password fields are excluded, and the URL isn't stored or logged. Mouthtype doesn't scrape the address bar or ask for extra browser permissions.

More detail and the limits are in the [writing tools reference](../WRITING-TOOLS.md).

## Related

- [Dictionary](dictionary.md) fixes names and spellings.
- [Transforms](transforms.md) rewrites text you've already written.
