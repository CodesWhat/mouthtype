# Writing tools and microphone priorities

Website tone rules, microphone priorities and selected-text transforms. Browser/device coverage and remaining physical acceptance limits are described below.

## Website rules

The Style page has website rules (add an app or website). A rule sets a tone, a cleanup level or both. The rule also matches subdomains.

### Add a rule

1. On the Style page, choose to add an app or website.
2. Add an ASCII domain such as `slack.com`.
3. Choose a tone (the existing Formal, Casual or Very Casual presentation), a cleanup level (Off, Basic, Fast or Thorough) or both.

### Precedence

1. The most specific matching domain wins.
2. The app rule.
3. The default.

A rule's cleanup level replaces the global cleanup level for takes on that site, and a field left on Use default falls back to the app rule, then the default. A level that needs a model that isn't installed runs as Basic.

Tone changes capitalization and ending punctuation. It does not add a freeform rewrite prompt.

> [!NOTE]
> Formal removes or softens swearing at Basic, Fast and Thorough (Off bypasses cleanup). Exclamations, emphasis and dismissals like "fuck off" are dropped, and swear nouns and verbs become a plain word ("asshole" becomes "jerk").

### Browser eligibility

Safari, Chrome, Edge and Brave are eligible when their focused window exposes its document URL through macOS Accessibility.

| Situation | Result |
| --- | --- |
| Document URL exposed | Website rules apply |
| URL unsupported or unavailable | The app/default style is used |
| Password fields and secure input | Excluded |
| HTTP/HTTPS hosts | Participate |
| Local files | Don't participate |

The URL lookup runs after capture starts and only when website rules exist. The selected style stays with that take. Document URLs used by these rules are not stored or logged.

What isn't used:

- No history.
- No address-bar scraping.
- No AppleScript.
- No additional browser permissions.

> [!NOTE]
> Automated tests cover domain boundaries, specificity, app fallback, legacy preferences, validation and capture ordering. Actual browser URL exposure and end-to-end dictation require coordinated desktop acceptance; eligibility is not a claim of verification in every browser/version.

## Microphone priority list

Settings → General → Microphone now offers Priority list alongside System Default and individual devices.

- Add microphones and move them up or down.
- At the start of each take Mouthtype picks the first connected listed device by stable device identity.
- Disconnected entries remain in the list for reconnection.
- System Default fallback is a separate opt-in. Without it, no listed device means an explicit unavailable-input error.
- The existing fixed-device setting keeps its behavior and does not silently fall back.

What the priority policy doesn't do:

- It doesn't change the Mac's system input.
- It doesn't switch devices mid-recording; an interrupted route still ends that take under the existing policy.
- It doesn't infer clamshell availability or claim verified Bluetooth/sleep behavior.

> [!WARNING]
> Fallback stays enabled while the priority list is empty. Add an input before turning it off. Removing the final input requires keeping fallback enabled so the saved list still has a usable policy.

## Clean selected text

Select text in an accessible editable field, then choose **Transform Selection** from Mouthtype's menu. A floating panel that doesn't take focus from your app shows the original with removed words struck through and a result with the added or changed characters highlighted. You can edit the result.

- **Clean up** uses the tone that applies to the app you're in. It's deterministic basic cleanup: filler removal, spoken punctuation and whitespace/capitalization. It does not expand phrases, rewrite numbers or use surrounding text.
- **Edit Transforms…** opens the Transforms page.
- The items are disabled when nothing is selected or Accessibility isn't granted, and the menu reads the selection within 150 ms or gives up.
- The old Formal, Casual and Very Casual items are gone. Formal and Casual are now the **More formal** and **More casual** transforms, Very Casual was dropped, and saved phrases no longer appear in this menu.

**Accept** requests replacement of that exact original selection through Accessibility. The app, field, selection range and selected text must still match. Password fields and secure input are excluded.

- When the selection changed or the app refuses the write, an amber notice names the app, Accept is disabled and **Copy result** becomes the main button.
- There is no automatic clipboard paste, key event, retry or fallback to a different field.
- One accepted request disables another submission.
- API acceptance is reported as a replacement request, not verified insertion.

Limits:

- The limit is 16,000 UTF-16 units.
- Original and preview text stay in memory until the panel closes; they are not added to dictation history or written to disk.
- Pending update installation waits until the preview is closed.
- Dictation, recovery, file jobs and update installation block preparation/acceptance while active.
- Automated/offscreen checks do not replace coordinated real-app replacement testing.

## AI transforms for selected text

Pick **Fix grammar**, **Make shorter**, **More formal** or **More casual** in the Transform Selection panel. The local Thorough cleanup model (Gemma 4 E4B) runs the one instruction on your selection. Nothing leaves the Mac and there is no free-form prompt.

The result appears in the same editable result box.

| Item | Model | Behavior |
| --- | --- | --- |
| Clean up | None (deterministic) | Basic cleanup of the selection |
| Fix grammar, Make shorter, More formal, More casual | Thorough (Gemma 4 E4B) | Runs the one instruction on your selection |
| Accept | n/a | Same guarded replacement as Basic cleanup (app, field, range and text must still match) |
| Retry | n/a | Shown only while an AI transform is chosen; reruns the transform |
| Cancel | n/a | Drops it |

Limits:

- There is no automatic paste and no whole-field replacement.
- After Accept, press <kbd>Command</kbd>+<kbd>Z</kbd> in the original app to undo, or use **Copy original**. Whether <kbd>Command</kbd>+<kbd>Z</kbd> restores the text depends on the target app, since the edit goes through Accessibility.
- Without the downloaded Thorough model the AI chips are disabled and a note under them says why. Download it in Settings.
- S1-mini does not run transforms.
