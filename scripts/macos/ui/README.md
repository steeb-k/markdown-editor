# UI scripts

The app can drive itself, so the real window can be checked without Accessibility permission
or synthetic system events. A script is a JSON array of steps; the app runs them on its main
run loop through the same paths a person would use (key events into the window, menu actions
through the responder chain, settings), writes PNG snapshots and `log.json`, and quits with a
non-zero status if an assertion failed.

```sh
scripts/macos/ui-script.sh scripts/macos/ui/smoke.json          # debug bundle -> build/ui/smoke/
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/big.json  # release build (timings)
SKIP_BUILD=1 scripts/macos/ui-script.sh my.json out/dir        # reuse build/Markdown.app
```

The harness is compiled into debug builds, and into release builds only with
`scripts/macos/bundle.sh --release --ui-script` (`-DUI_SCRIPT`). It runs only when the app is
launched with `--ui-script <file>` (`--ui-out <dir>`, `--ui-root <dir>` for relative paths). It
uses its own defaults suite (never the user's settings) and opens copies of the files it is
given. Set `UI_SCRIPT_TRACE=1` to log every step as it starts.

Snapshots are composited by the app itself (the text view rendered as vector PDF, then the
toolbar, fade and title-bar controls on top): vibrancy blur is not reproduced, and sheets are
captured with `"window": "sheet"`.

## Steps

| Step | Does |
| --- | --- |
| `{"open": "path"}` | Opens a copy of a file (relative to `--ui-root`, the cwd or the script). `"folder": true` also copies everything beside it (the images a document refers to by relative path). |
| `{"openGenerated": {"from": "path", "minLength": 1000000}}` | Opens `from` repeated to at least that many UTF-16 units. |
| `{"new": true}`, `{"load": "text"}` | New untitled document; replace its text. |
| `{"type": "text", "interval": 0.05}` | Key events (`\n` Return, `\t` Tab, `⇤` Shift-Tab). |
| `{"key": {"chars": "b", "mods": ["cmd"]}}` | One key event; Command keys go through the main menu. |
| `{"select": [loc, len]}`, `{"selectText": "needle", "offset": n, "length": n}` | Selection. |
| `{"action": "toggleStrong:", "tag": 2}` | `NSApp.sendAction` (tag for heading level, alignment). An action that edits runs as one undo group; `"edits": false` (view toggles such as `toggleFocusMode:`, and `{"command": ...}` moves) sends it plain, because a closed empty undo group marks the document edited. |
| `{"command": "insertNewline:"}` | `doCommand(by:)` on the text view. |
| `{"setting": {"theme": "dark", "fontChoice": "iaDuo", "fontSize": 20, "lineWidth": 60, "defaultViewMode": "source", ...}}` | Settings. |
| `{"appearance": "dark"}` | App appearance (`light`, `dark`, `system`), for the System theme. |
| `{"wait": 0.5}`, `{"waitStyled": 20}` | Time; styling caught up. |
| `{"snapshot": "name", "window": "settings"}` | PNG of the document window, Settings or the attached sheet. `"bitmap": true` renders the text view as it is drawn on screen (selection highlight and caret included; the default vector rendering leaves them out). |
| `{"resize": [w, h]}`, `{"fullscreen": true}`, `{"scroll": "end"}` | Window. Full screen is skipped when the app is not active. |
| `{"newTab": true}`, `{"switchTo": 0}`, `{"settingsWindow": "show"}`, `{"sheet": "end"}` | Windows. |
| `{"pointer": "moved"}` | What a mouse move does to the auto-hiding chrome. |
| `{"undo": true}`, `{"redo": true}` | Document undo manager. |
| `{"viewMode": "live"}` | Sets the window's view mode (`source`, `live`); the title-bar switch and View menu do the same. New windows start in Source unless `defaultViewMode` says otherwise: every script sets the mode it needs. |
| `{"clickCheckbox": 0}`, `{"cmdClickLink": "needle"}`, `{"dropFile": "path"}` | The n-th task checkbox is clicked; the link under the needle is Cmd-clicked (nothing is really opened: the URL is recorded for `linkOpened`); a file is dropped at the caret. |
| `{"httpServe": "dir", "port": 8765}` | Serves a folder on `http://127.0.0.1:port/` from inside the app (remote pictures without the internet). |
| `{"copyFile": {"from": "path", "to": "work/x.png"}}`, `{"revalidateImages": true}` | Replaces a file beside the opened copy (`to` is relative to the output directory); rechecks pictures on disk, as the window becoming key does. |
| `{"pasteImage": "path.png", "wait": 3}` | Pastes PNG data from a private pasteboard (Edit > Paste's image path); waits for it to be written, or for the save panel. |
| `{"waitImages": 5}`, `{"dumpLayout": "needle"}` | Waits for pictures to load; logs line fragments and glyph positions (`N` null, `C` control) of the paragraph holding the needle. |
| `{"measureTyping": {"count": 150, "interval": 0.06, "maxMs": 10}}` | Main-thread time per keystroke and the longest run-loop gap. |
| `{"measureCaret": {"count": 200, "stride": 97}}` | Main-thread time per caret move (the selection change and the concealment it triggers). |
| `{"caretWalk": {"command": "moveRight:"}}` | Presses the key until the caret stops (or comes back to a place it has been: Right through a right-to-left line moves backwards, as AppKit does in Source mode too); fails if a press passed only hidden text or the caret rested in hidden text (Live mode's caret rules). |
| `{"measureKeys": {"count": 200, "command": "moveRight:"}}` | Main-thread time per arrow-key press through the key bindings, drawing included. |
| `{"measureJump": {"count": 20}}` | Time to scroll to a far place and lay out and draw the screenful there (a scroll-smoothness proxy). |
| `{"focus": {"on": true, "scope": "paragraph"}}` | Focus mode for this window (`on`) and the scope setting (`sentence`, `paragraph`); asks for the focus range at once. |
| `{"syntax": {"on": true, "classes": ["noun", "verb"]}}`, `{"waitSyntax": 30}` | Syntax highlighting for this window, and the classes (a setting: the five names, the rest are switched off); waits until tagging has settled. |
| `{"close": true}` | Closes the document and checks that it, its window controller, session and coordinator are freed. |
| `{"controlLeakProbe": true}` | The same check for a plain AppKit window (AppKit keeps closed windows for a while). |
| `{"dump": true}`, `{"log": "text"}` | Diagnostics. |
| `{"assert": {...}}` | `textEquals`, `textContains`, `textLacks`, `selection`, `selectedText`, `toolbarLit`, `headingTitle`, `chromeVisible`, `toolbarIgnoresClicksWhenHidden`, `inTable`, `theme`, `styled`, `coreMatchesText`, `edited`, `fullScreen`, `sheet`, `fontFamily`, `boldDiffers`, `columnCentered`, `caretVisible`, `spellingAllowedIn`, `spellingSuppressedIn`, `closedDocumentsFreed`, `viewMode`, `hidden` (the exact list of hidden source pieces), `decorations` (counts per kind), `collapsedLines`, `linkOpened`, `images` (picture decorations per phase: `loaded`, `failed`, `loading`), `assets` (files in `<document>.assets`), `pasted`, `focusing`, `syntaxing`, `focusLit` (the text of the focus ranges), `colors` (what the text at each needle is painted in: `none`, `dim`, a class; checked against the layout manager's own temporary attributes), `overlayConsistent` (every character's temporary colour equals what the layers say), `overlayStats` (logs the overlay's operation counts and the tagger's). |

## Scripts

| Script | What it shows |
| --- | --- |
| `smoke.json` | The M2 tour: typography, themes, chrome, commands, tables, closing. |
| `live.json` | Live mode: a tour document with the caret in plain prose (no markup visible; bullets, checkboxes, rule, quote bar and picture drawn; fences collapsed), then entering bold, a link, a heading, a code block, an image paragraph, a quote, front matter and a setext heading; a checkbox click and its undo; typing in Live mode; Cmd-click on a link; Source and back; other themes; Settings. |
| `live-edge.json` | Nested quotes, headings and tasks in quotes, a fence in a list item, footnotes, reference links, hard breaks, raw HTML, an unclosed fence, in three themes. |
| `live-look.json` | Live mode by eye: lists, tasks, quotes in lists and lists in quotes, headings and fences in lists, an empty code block, wrapping code and strikethrough, Hebrew and Japanese beside hidden markup, spelling marks; pictures standalone, inline, in a list item and a quote, broken, remote (served locally), tall, wide, twice, changed on disk; selections over all of it; three themes; dropping files and pasting image data (unique names); an untitled document's relative picture and the save panel when pasting into it. |
| `focus.json` | Focus mode by eye (snapshots are bitmaps: the vector PDF rendering ignores temporary attributes): the caret in a paragraph, across a soft break, in a list item, a task, a code block, a quote, on a blank line; Source and Live, sentence and paragraph, Light, Dark and Sepia; bullets, boxes, bars, rules, strikethrough, inline-code chips and pictures receding with their text; focus switched off again. With `focusLit`, `colors` and `overlayConsistent` assertions. |
| `syntax.json` | Parts-of-speech colours: all five classes, then nouns and verbs only, then the other three; with focus mode (dimmed words show no colour); Source and Live; Light, Dark and Sepia; switched off. |
| `big-focus.json` | A 1 MB document, a fresh one per configuration: per-keystroke, per-caret-move and per-arrow-key main-thread cost with focus and syntax off, on, and both, in Source and Live (run with `RELEASE=1`). |
| `big.json`, `big-live.json` | A 1 MB document: typing, caret moves, arrow keys and jumps in Source mode and in Live mode (run with `RELEASE=1`). |
| `threshold.json` | Live mode either side of the whole-text query limit (run with `RELEASE=1`). |

`fixtures/live.md`, `fixtures/live-edge.md` and `fixtures/live-look.md` use the pictures in `fixtures/images/`.
