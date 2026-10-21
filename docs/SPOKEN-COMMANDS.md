# Spoken commands and counted lists

**Settings → Advanced → Spoken commands and lists** controls this and is on by default. You can say punctuation, line breaks and lists instead of typing them. The one switch drives both the commands and counted lists. This page lists what exists today; nothing else is a command.

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

- Cardinals followed by a comma or colon: "one, ... two, ... three, ...", up to ten. A bare cardinal after a comma ("three things, one call the bank, two email Priya") counts when there are three or more markers or the lead-in announces a count.
- Digits: "1, ... 2, ...", up to 12, with a comma or colon after each.
- Ordinals: "first, second, third" or "firstly, secondly", up to tenth, and "first of all". "Lastly", "finally" or "last," closes a run that already has two ordinals and takes the next number.
- Prefixed numbers: "number one", "step one", "point one", "option one", and "option a, option b" with a comma or colon after the letter.
- Parenthesized markers: "(a), (b)" and "(1), (2)".

Each item goes on its own line as `N. Item`, with the first word capitalized and a trailing comma or semicolon dropped. The last item ends with its sentence, and text after it moves to a new line. Text before the first marker stays as a line above. A full stop ending a lead-in that announces a count ("three things.") becomes a colon. Lines that already start with `- ` or `1. ` are left alone.

A first marker after a comma works when the lead-in announces a count: "I have three things, first, call the bank. Second, email Priya." becomes "I have three things:" followed by `1. Call the bank.` and `2. Email Priya.`

Counting that is just counting stays as it is. "One, two, three apples" has no item text, and "number one is the price" or "came second" read as sentences.

## Slash commands in coding apps

In a terminal, code editor or agent app, saying "slash" or "forward slash" and a word types a slash command. "Do we want to do a slash research?" becomes "Do we want to do a /research?". It works anywhere in the text and keeps the punctuation after the command.

- The word is lowercased and joined with no space: "slash Research" becomes "/research".
- "dash", "hyphen" and "underscore" join more words: "slash code dash review" becomes "/code-review", "slash pr underscore comments" becomes "/pr_comments".
- A standalone "Slash research." drops the engine's closing punctuation and types "/research". Inside a sentence the punctuation stays after the name.
- Talk about the character is left alone: "the slash key", "a forward slash separates paths", "double slash".
- A bare "slash", "slash 2", or "slash" before a plain function word ("and slash or") stays as spoken. So does a command already typed with "/", text in backticks, and anything your dictionary covers.
- It runs only for these targets: Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm, Alacritty, VS Code, Cursor, Zed, Xcode, Windsurf, the JetBrains IDEs, the Claude, ChatGPT, Codex and Orca apps, and claude.ai or chatgpt.com in Safari, Chrome, Edge or Brave. Everywhere else the words are left alone.

**Settings → Advanced → Slash commands in coding apps** turns it off. It is on by default.

## Known misses

- Bare letters ("a, b, c") aren't markers without the word "option".
- Prose that happens to count ("First, thanks. Second, I'm late.") reads as a list.
- A list item that really contains "next" as prose can be split.

Turn the switch off in Settings → Advanced if a command word keeps getting in your way.
