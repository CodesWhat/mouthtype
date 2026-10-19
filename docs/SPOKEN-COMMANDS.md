# Spoken commands and counted lists

Turn on **Settings → Writing → Spoken commands and lists** to say punctuation, line breaks and lists instead of typing them. The same switch covers counted lists. This page lists what exists today; nothing else is a command.

Commands run in the text rules of the cleanup pass, so Cleanup Off bypasses them. Mouthtype only treats a phrase as a command when the surrounding words say it is one. Ordinary speech like "the period ended" or "a new line of products" stays as written. Check the result when a command word is also a real word.

## Punctuation

| Say | Get | Notes |
| --- | --- | --- |
| comma | , | Attaches to the word before. Stays prose after "the Oxford comma", before "splice", or after a verb like "add" |
| colon | : | Same rules as comma |
| semicolon, semi colon | ; | Same rules as comma |
| period, full stop | . | Only at the end of a clause, so "the period ended" stays prose. The next word gets a capital |
| question mark | ? | The next word gets a capital |
| exclamation point, exclamation mark | ! | The next word gets a capital |
| ellipsis, dot dot dot | … | |
| dash | - | With a space on each side |
| hyphen | - | No spaces |
| at sign | @ | No spaces |
| ampersand | & | With a space on each side |
| open paren, open parenthesis | ( | Attaches to the next word |
| close paren, close parenthesis | ) | Attaches to the word before |
| open quote | " | Attaches to the next word |
| close quote, end quote | " | Attaches to the word before |

A noun use right before the command word, such as "a question mark" or "the first dash", keeps it as a word.

## Layout

| Say | Get |
| --- | --- |
| new line, newline | A line break |
| new paragraph | A blank line. Also closes an open list |

These are commands unless a determiner or possessive sits right before them ("a new line of products"). A comma, semicolon or colon right before them is dropped, and the next word gets a capital.

## Lists you ask for

| Say | Get |
| --- | --- |
| bullet, bullet point | Starts a bulleted list item. Needs item text after it |
| new bullet | Another bullet item |
| numbered list | Starts a numbered list at `1.`. Needs item text after it |
| next item, new item | The next item in the open list |
| next | The next item, only inside an open list and only where it doesn't read as prose ("what's next", "next week" stay words) |
| end list, end of list | Closes the list |

"Bullet" as a noun ("the bullet hit", "bullet train", "bullet points are") is left alone. Each item goes on its own line with the first word capitalized.

## Counted lists

You don't need a command to get a numbered list. If you count out loud, Mouthtype turns the run into `1.`, `2.`, `3.` lines. A run needs at least two markers, in order from the first with no gaps, and the first has to start a clause. Use one marker style throughout a run:

- Cardinals followed by a comma or colon: "one, ... two, ... three, ...", up to ten.
- Ordinals: "first, second, third" or "firstly, secondly", up to tenth, and "first of all". "Lastly", "finally" or "last," closes a run that already has two ordinals and takes the next number.
- Prefixed numbers: "number one", "step one", "point one", "option one", and "option a, option b" with a comma or colon after the letter.
- Parenthesized markers: "(a), (b)" and "(1), (2)".

Each item goes on its own line as `N. Item`, with the first word capitalized and a trailing comma or semicolon dropped. The last item ends with its sentence, and text after it moves to a new line. Text before the first marker stays as a line above. A full stop ending a lead-in that announces a count ("three things.") becomes a colon. Lines that already start with `- ` or `1. ` are left alone.

Counting that is just counting stays as it is. "One, two, three apples" has no item text, and "number one is the price" or "came second" read as sentences.

## Known misses

- A first marker after a comma ("I have three things, first, ...") isn't read as a list.
- Bare letters ("a, b, c") aren't markers without the word "option".
- Prose that happens to count ("First, thanks. Second, I'm late.") reads as a list.
- A list item that really contains "next" as prose can be split.

Turn the switch off in Writing if a command word keeps getting in your way.
