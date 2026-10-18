# Writing tools and microphone priorities

Available starting in 0.1.0-alpha.9. Browser/device coverage and remaining physical acceptance limits are described below.

## Website tone

Settings → Writing has a Website tone section. Add an ASCII domain such as `slack.com` and choose the existing Formal, Casual or Very Casual presentation. The rule also matches subdomains. The most specific matching domain wins, followed by the app rule, then the default. Tone changes capitalization and ending punctuation; it does not add a freeform rewrite prompt or change the cleanup level.

Safari, Chrome, Edge and Brave are eligible when their focused window exposes its document URL through macOS Accessibility. An unsupported or unavailable URL uses the app/default style. Password fields and secure input are excluded. No history, address-bar scraping, AppleScript or additional browser permissions are used. Only HTTP/HTTPS hosts participate; local files do not. The URL lookup runs after capture starts and only when website rules exist. The selected style stays with that take. Document URLs used by these rules are not stored or logged.

Automated tests cover domain boundaries, specificity, app fallback, legacy preferences, validation and capture ordering. Actual browser URL exposure and end-to-end dictation require coordinated desktop acceptance; eligibility is not a claim of verification in every browser/version.

## Microphone priority list

Settings → General → Microphone now offers Priority list alongside System Default and individual devices. Add microphones and move them up or down. At the start of each take Mouthtype picks the first connected listed device by stable device identity. Disconnected entries remain in the list for reconnection.

System Default fallback is a separate opt-in. Without it, no listed device means an explicit unavailable-input error. The existing fixed-device setting keeps its behavior and does not silently fall back. The priority policy does not change the Mac's system input. It does not switch devices mid-recording; an interrupted route still ends that take under the existing policy. It does not infer clamshell availability or claim verified Bluetooth/sleep behavior.

## Clean selected text

Select text in an accessible editable field, then choose **Clean Selected Text…** from Mouthtype's menu. A nonactivating preview shows the original and a result you can review or edit. This first version uses deterministic basic cleanup: filler removal, spoken punctuation and whitespace/capitalization. It does not run an AI rewrite, expand phrases, rewrite numbers or use surrounding text.

**Accept** requests replacement of that exact original selection through Accessibility. The app, field, selection range and selected text must still match. Password fields and secure input are excluded. Unsupported or changed selections keep the result available through **Copy result**. There is no automatic clipboard paste, key event, retry or fallback to a different field. One accepted request disables another submission. API acceptance is reported as a replacement request, not verified insertion.

The limit is 16,000 UTF-16 units. Original and preview text stay in memory until the panel closes; they are not added to dictation history or written to disk. Pending update installation waits until the preview is closed. Dictation, recovery, file jobs and update installation block preparation/acceptance while active. Automated/offscreen checks do not replace coordinated real-app replacement testing.
