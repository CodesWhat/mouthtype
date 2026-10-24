# Languages

Development builds support 28 languages: the 25 Parakeet v3 languages, plus Japanese, Hindi and Tamil through Whisper Turbo. The three new languages are in Beta. English gets every cleanup rule; other languages get the smaller set below.

> [!NOTE]
> The released 0.6.0 app supports the 25 Parakeet languages. The Whisper routing described here is in development and is not part of that release.

> [!NOTE]
> Dictation language is separate from the language of the app. Mouthtype's menus and settings are English only.

## Choosing a language

**Settings → General → Language** has three kinds of choice.

| Choice | What happens |
| --- | --- |
| Auto-detect (the default) | Each take picks its language from what you said, among English and the languages in your Mac's preferred language list that Mouthtype supports. |
| English | Every take is English. Nothing is detected. |
| Any other listed language | Every take is that language. Nothing is detected. |

- The info button beside the Language row shows the same English-only breakdown as the support matrix below.
- On a Mac whose preferred languages are English only, Auto-detect has one candidate, skips detection and behaves exactly as 0.5.0 did.
- With two or more candidates, Parakeet takes use Apple's language recognizer on the finished transcript, limited to those candidates. A take with fewer than 3 words, or one the recognizer isn't confident about, uses the first candidate, normally English. Whisper takes keep the engine's detected language when it is one of the candidates, including Japanese text without spaces.
- A setting that includes Japanese, Hindi or Tamil uses Whisper Turbo for every take, including English in that Auto-detect set. The first use downloads a separate model of about 1.6 GB. Settings and Setup show its preparation state. Settings changes prepare the new model before another recording can start; a take already recording keeps its original language.
- Live words aren't available while using Whisper Turbo. The saved Live words preference applies again when you return to a Parakeet language setting.
- Each take has one language. Switching language in the middle of a sentence isn't supported. The speech model usually keeps both languages in the text, but cleanup treats the take as one language.
- Pick the language yourself if Auto-detect keeps guessing wrong for you.

## Support matrix

Word error rates are from FluidAudio's published FLEURS results for Parakeet v3. Lower is better. Languages marked Beta are the ones at 25 percent or worse, where expect more corrections. Portuguese isn't in the published table.

| Language | Recognition (FLEURS word error) | Thorough cleanup |
| --- | --- | --- |
| English | 5.4 percent | Yes |
| Italian | 4.0 percent | Yes |
| Spanish | 4.5 percent | Yes |
| French | 5.9 percent | Yes |
| German | 5.9 percent | Yes |
| Russian | 7.2 percent | Yes |
| Ukrainian | 7.2 percent | Basic only |
| Dutch | 7.8 percent | Yes |
| Polish | 8.6 percent | Yes |
| Portuguese | Not published | Yes |
| Czech, Slovak, Bulgarian, Croatian, Romanian, Finnish | 12 to 15 percent | Basic only |
| Swedish, Hungarian, Estonian, Danish | 16 to 20 percent | Basic only |
| Lithuanian (Beta) | 25.0 percent | Basic only |
| Maltese (Beta) | 25.2 percent | Basic only |
| Latvian (Beta) | 27.1 percent | Basic only |
| Slovenian (Beta) | 27.4 percent | Basic only |
| Greek (Beta) | 36.9 percent | Basic only |

The development branch also offers these Whisper languages. These measurements are from five synthetic macOS-voice clips per language, not FLEURS or fluent speakers, and aren't directly comparable to the table above.

| Language | Speech model | Synthetic measurement | Thorough cleanup |
| --- | --- | --- | --- |
| Japanese (Beta) | Whisper Turbo | 2.1 percent character error | Basic only |
| Hindi (Beta) | Whisper Turbo | 18 percent word error | Basic only |
| Tamil (Beta) | Whisper Turbo | 27 percent word error | Basic only |

Basic only means the take gets the Basic rules and the Thorough model doesn't run for that language yet. Synthetic clips verify routing and script output; a fluent tester still needs to check real dictation.

## What runs outside English

| Stage | Outside English |
| --- | --- |
| Punctuation and capitalization from the speech model | Runs |
| Your dictionary and snippets | Run. One dictionary covers every language, so a heard form you saved applies in all of them. |
| Spoken technical notation ("U S B" to USB) | Runs |
| Whitespace tidy, insertion spacing, tone's drop-final-stop | Run |
| Fillers and stutter collapse | English only |
| Spoken commands and slash commands | English only |
| Counted lists | English only |
| Self-correction ("no, I mean") | English only |
| Number formatting | English only |
| Swearing removal and the Formal tone's promise | English only |
| Boost saved words | English only. It runs when English is a candidate. |
| Dictionary suggestions | Only from English takes |

These rules are off because they match English words. "Ten" is a number in English and a different word in Polish, Czech, Slovak and Dutch, and "no" is a negation in Spanish, Italian and Portuguese. Running them on those languages would change text that was right.

### Cleanup levels

| Level | Outside English |
| --- | --- |
| Off | The speech model's text as it is. |
| Basic | The rows above. |
| Fast | English only. In another language Mouthtype uses Basic and says so under the level choice. |
| Thorough | German, Spanish, French, Italian, Portuguese, Dutch, Polish and Russian. Other languages get Basic. |

Thorough's language support comes from a measured run (see the [Thorough cleanup by language evaluation](evals/language-cleanup-2026-10.md)). On its fixture set the model's output passed the safety guard and stayed in the spoken language for all eight, with no translation. The fixtures are small, 9 to 12 takes per language, and mostly already-clean text, so treat it as a first pass and not a guarantee. Thorough is given more time per word for Polish, Russian and Greek, because their words take the model more work than English ones.

## What the measurements say

These are Mouthtype's own engine measurements from 22 October 2026, using synthetic speech from macOS voices, 5 sentences per language, so real speech will be worse. They explain the choices above.

- Parakeet's language setting is a script filter, not language conditioning. It only blocks tokens in the wrong script. For Latin-script languages (German, French, Spanish, Italian, Portuguese, Dutch, Polish) the English setting, no setting and the language's own setting produced identical text on all 35 clips.
- Russian, Ukrainian, Bulgarian and Greek need no English hint (Russian and Greek were measured). With the English hint, Russian had 86.8 percent word error and Greek 90.4 percent, all of it Latin transliteration. With no hint, Russian had 1.5 percent and Greek 34.2 percent. Mouthtype sends no English hint whenever one of those languages is a possibility.
- Parakeet is fast, about 53 ms for a typical clip. Whisper large-v3 turbo is about 690 ms, and about 940 ms for Greek.
- Parakeet doesn't detect language. Mouthtype detects from the transcript, which got 50 of 50 right on the languages Parakeet supports when limited to the candidate languages.
- Spoken language switching inside a take: Parakeet kept both languages in all 5 test clips. This is a test result, not a supported feature.
- Whisper engines now decode in the resolved language, or detect it, instead of forcing English. Forced English made Whisper translate or return nothing for non-English speech (47.9 percent word error on the Latin set).

## Not supported yet

| Language | Status |
| --- | --- |
| Telugu, Bengali, Kannada and other Indian languages | Not supported. Parakeet v3 has no Indian-language support and returns romanized gibberish that looks like text. Whisper measured 41 to 74 percent word error for Telugu, Bengali and Kannada on synthetic speech. A dedicated model (AI4Bharat IndicConformer) is the planned route for real quality. |
| Chinese, Korean, Arabic and others | Not supported. |
| Indian English | Works on the default path (6 percent word error on synthetic speech). |

Japanese, Hindi and Tamil routing is not in the released 0.6.0 app. IndicConformer isn't integrated.

## Other limits

- A language other than English is only as good as the speech model. Parakeet decodes in the language it hears, and the language setting can't force it. A hesitant take in German can still come back in English.
- Number formatting, spoken commands, fillers and self-correction in other languages are future work. Per-language versions are not in 0.6.0.
- French punctuation spacing before `?`, `!`, `:` and `;` is kept as the speech model writes it.
- See [known limits](KNOWN-LIMITS.md) for the rest.
