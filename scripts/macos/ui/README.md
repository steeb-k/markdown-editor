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
| `{"open": "path"}` | Opens a copy of a file (relative to `--ui-root`, the cwd or the script). |
| `{"openGenerated": {"from": "path", "minLength": 1000000}}` | Opens `from` repeated to at least that many UTF-16 units. |
| `{"new": true}`, `{"load": "text"}` | New untitled document; replace its text. |
| `{"type": "text", "interval": 0.05}` | Key events (`\n` Return, `\t` Tab, `⇤` Shift-Tab). |
| `{"key": {"chars": "b", "mods": ["cmd"]}}` | One key event; Command keys go through the main menu. |
| `{"select": [loc, len]}`, `{"selectText": "needle", "offset": n, "length": n}` | Selection. |
| `{"action": "toggleStrong:", "tag": 2}` | `NSApp.sendAction` (tag for heading level, alignment). |
| `{"command": "insertNewline:"}` | `doCommand(by:)` on the text view. |
| `{"setting": {"theme": "dark", "fontChoice": "iaDuo", "fontSize": 20, "lineWidth": 60, ...}}` | Settings. |
| `{"appearance": "dark"}` | App appearance (`light`, `dark`, `system`), for the System theme. |
| `{"wait": 0.5}`, `{"waitStyled": 20}` | Time; styling caught up. |
| `{"snapshot": "name", "window": "settings"}` | PNG of the document window, Settings or the attached sheet. |
| `{"resize": [w, h]}`, `{"fullscreen": true}`, `{"scroll": "end"}` | Window. Full screen is skipped when the app is not active. |
| `{"newTab": true}`, `{"switchTo": 0}`, `{"settingsWindow": "show"}`, `{"sheet": "end"}` | Windows. |
| `{"pointer": "moved"}` | What a mouse move does to the auto-hiding chrome. |
| `{"undo": true}`, `{"redo": true}` | Document undo manager. |
| `{"measureTyping": {"count": 150, "interval": 0.06, "maxMs": 10}}` | Main-thread time per keystroke and the longest run-loop gap. |
| `{"close": true}` | Closes the document and checks that it, its window controller, session and coordinator are freed. |
| `{"controlLeakProbe": true}` | The same check for a plain AppKit window (AppKit keeps closed windows for a while). |
| `{"dump": true}`, `{"log": "text"}` | Diagnostics. |
| `{"assert": {...}}` | `textEquals`, `textContains`, `textLacks`, `selection`, `selectedText`, `toolbarLit`, `headingTitle`, `chromeVisible`, `toolbarIgnoresClicksWhenHidden`, `inTable`, `theme`, `styled`, `coreMatchesText`, `edited`, `fullScreen`, `sheet`, `fontFamily`, `boldDiffers`, `columnCentered`, `caretVisible`, `spellingAllowedIn`, `spellingSuppressedIn`, `closedDocumentsFreed`. |
