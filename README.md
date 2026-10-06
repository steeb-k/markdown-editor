# markdown

A native macOS Markdown editor on a shared Rust core, built for writing: styled source, a preview, focus mode, a notes library with wikilinks and tags, and a history of every pause.

Requirements: Xcode 26+, Rust (rustup) with `aarch64-apple-darwin` and `x86_64-apple-darwin` targets. No other tools needed (UniFFI's bindgen is a workspace binary).

```sh
# Rust tests (spans, markup, offsets, dirty ranges, proptest, CommonMark spec, insta snapshots,
# an oracle against pulldown-cmark's event stream, editing commands, tables, bare-URL autolinks, themes,
# focus ranges, part-of-speech units, authorship: run arithmetic and the
# Markdown Annotations format, and the HTML renderer: fixture snapshots, every CommonMark example, GFM,
# data-line, slugs, the sanitizer, fragments, highlighting, the stylesheet and its contrast)
cargo test --workspace
# Heavier fuzzing: the `fuzz` profile is optimized but keeps debug assertions, so the span
# sanitizer's "nothing was dropped" check stays armed.
# PROPTEST_CASES=200000 cargo test --profile fuzz -p markdown-core --test properties
# ORACLE_CASES=1000000 cargo test --profile fuzz -p markdown-core --test oracle
# FUZZ_CASES=1000000 cargo test --profile fuzz -p markdown-core --test robustness -- --include-ignored random_documents
# PROPTEST_CASES=100000 cargo test --profile fuzz -p markdown-core --test command_props      # editing commands and tables
# PROPTEST_CASES=100000 cargo test --profile fuzz -p markdown-core --test command_oracle     # commands judged by pulldown-cmark
# SWEEP_STRIDE=1 cargo test --profile fuzz -p markdown-core --test command_props every_command  # every command on every selection
# INSTA_UPDATE=always cargo test -p markdown-core --test fixtures       # accept changed snapshots (review the diff!)
# PROPTEST_CASES=1000000 cargo test --profile fuzz -p markdown-core --test authorship   # authorship arithmetic and the file format
# cargo test -p markdown-core --test authorship -- --ignored spec_readme    # the format's own README (fetched, not vendored) still verifies
# cargo test --release -p markdown-core --test perf -- --ignored --nocapture         # 1 MB timing, HTML rendering included
# RENDER_FUZZ_CASES=50000 cargo test --profile fuzz -p markdown-core --test render   # render fuzzing, sanitizer soup checked by a browser-faithful tokenizer
# RENDER_DIFF_CASES=1000000 cargo test --profile fuzz -p markdown-core --test render_diff   # the renderer against pulldown-cmark's own writer, additions normalised away
# cargo test --release -p markdown-core --test perf -- --ignored --nocapture worst_case   # no 1 MB render over 100 ms (highlighting budget)
# cargo test --release -p markdown-core --test perf -- --ignored --nocapture history_diff   # the history's line diff of a 1 MB document with one line changed (under 50 ms)
# cargo test --release -p markdown-core --test robustness -- --ignored --nocapture one_megabyte   # 1 MB worst cases
# cargo test --release -p markdown-core --test code -- --ignored --nocapture            # editor code highlighting: 1 MB with 200 blocks, a 2 000-line block

# Build the core: static lib + Swift bindings + XCFramework (host arch, debug)
scripts/build-core.sh                 # or --release, or --universal (arm64+x86_64, release)

# Swift build and tests (after build-core.sh)
cd apps/macos && swift build && swift test
# Longer random walks: AUTHORSHIP_ROUNDS=40 AUTHORSHIP_STEPS=300 swift test --filter AuthorshipRandom
#                      OVERLAY_SEEDS=6 swift test --filter OverlayRandomTests

# Assemble and ad-hoc sign build/Markdown.app (runs build-core.sh and swift build)
scripts/macos/bundle.sh               # or --release, or --universal
open build/Markdown.app

# Real signing: CODESIGN_IDENTITY="Developer ID Application: ..." scripts/macos/bundle.sh --release --universal
# What is inside a bundle (exact file list, both slices, minimum OS, no harness code, hardened runtime):
scripts/macos/verify-bundle.sh build/Markdown.app --universal --no-harness

# The release script's control flow without Apple: dry run, refusals, stubbed notary verdicts (see "Releasing")
scripts/macos/tests/release-pipeline.sh

# The app icon is built by bundle.sh from assets/ (see "Icons" below); nothing to regenerate by hand
# Regenerate Acknowledgements.md from the dependency graph (cargo metadata); --check says whether it is current
scripts/gen-acknowledgements.py

# Drive the real app from a JSON script (no Accessibility permission needed): snapshots + log.json
scripts/macos/ui-script.sh scripts/macos/ui/smoke.json          # -> build/ui/smoke/
scripts/macos/ui-script.sh scripts/macos/ui/look.json           # the M2 look: the tour in three themes, Settings
scripts/macos/ui-script.sh scripts/macos/ui/focus.json          # focus mode, sentence and paragraph, three themes
scripts/macos/ui-script.sh scripts/macos/ui/code.json           # code highlighting: theme colours, the language badge and its menu, focus mode
scripts/macos/ui-script.sh scripts/macos/ui/syntax.json         # parts-of-speech colours, classes switched off, with focus mode
scripts/macos/ui-script.sh scripts/macos/ui/authorship.json     # Paste As, Mark As (Edit menu and context menu, with Mark This Passage As over a run), typing in borrowed text, undo, save and reopen; three themes
scripts/macos/ui-script.sh scripts/macos/ui/authorship-mismatch.json  # the keep-or-discard sheet for marks that may be misplaced
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/big.json  # 1 MB typing timings, release build
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/threshold.json  # typing, caret moves and jumps either side of 150,000 units
scripts/macos/ui-script.sh scripts/macos/ui/preview.json        # Split and Preview layouts: three themes, typing, scroll sync both ways, links, fonts, snapshots of the web view
scripts/macos/ui-script.sh scripts/macos/ui/preview-export.json # PDF export (Dark, Sepia; preview hidden, split, preview): pages, text, picture, white page, margins
scripts/macos/ui-script.sh scripts/macos/ui/preview-edge.json   # pictures of every kind in editor and preview alike, links of every kind, a hostile document, themes and fonts, untitled
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/preview-big.json   # 1 MB in Split: typing with the preview closed and open, preview latency, main-thread cost of an update (≤ 16 ms)
scripts/macos/ui-script.sh scripts/macos/ui/soak.json           # everything together at random, checked after every step
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/drift.json  # a long session at 1 MB: cost per key and per jump must not grow (about 9 minutes)
scripts/macos/ui-big-focus.sh                                   # 1 MB, release: focus, syntax and authorship off vs on, and a save
scripts/macos/ui-script.sh scripts/macos/ui/acceptance.json     # 1.0 end to end: a document made with menus and typing, saved, exported, copied, reopened
scripts/macos/ui-script.sh scripts/macos/ui/pictures.json       # pictures at their declared resolution; Up and Down keep their column through one
scripts/macos/ui-script.sh scripts/macos/ui/polish.json         # code panels in lists and quotes, pictures at every resolution in editor, preview and PDF
scripts/macos/ui-script.sh scripts/macos/ui/first-run.json      # the first window, the scroll limit, Help and Acknowledgements
scripts/macos/ui-script.sh scripts/macos/ui/lifecycle.json      # 50 documents opened and closed: everything freed, memory flat
scripts/macos/ui-script.sh scripts/macos/ui/robust.json         # 10 MB, a 5 MB line, binary, changed on disk, read-only, odd names, empty, mixed endings
scripts/macos/ui-script.sh scripts/macos/ui/edge.json           # tiny window, documents of only front matter/table/picture/nothing, windows in different modes, everything on at once
scripts/macos/ui-script.sh scripts/macos/ui/scroll-limits.json  # the editor's scroll limits in every layout, resized, with the find bar
scripts/macos/ui-script.sh scripts/macos/ui/notes.json          # notes mode: sidebar, a click replaces the window's document, Command-click opens a window, search, tags, backlinks within a second
scripts/macos/ui-script.sh scripts/macos/ui/notes-files.json    # new note and folder, rename with link updates and undo, drag, Trash, templates, today's note
scripts/macos/ui-script.sh scripts/macos/ui/notes-links.json    # wikilinks: Cmd-click and preview clicks, plain mode and notes mode, a link to nothing
scripts/macos/ui-script.sh scripts/macos/ui/quick-open.json     # the palette: fuzzy on titles and paths, arrows, Return, Command-Return, Escape
scripts/macos/ui-script.sh scripts/macos/ui/windows.json        # one document per window: no tabs, the title in the title bar, a click replaces the document, Command-click and Command-Option-click open windows
scripts/macos/ui-script.sh scripts/macos/ui/edited.json         # a titled document shows "Edited" only before its autosave: plain and notes mode, every layout and mode, the side column on either pane
scripts/macos/ui-script.sh scripts/macos/ui/autosave.json       # written 2 s after the last keystroke, no edited dot, nothing asked on close, another app's newer file, drafts
scripts/macos/ui-script.sh scripts/macos/ui/history.json        # snapshots after a pause, Save, the panel, diff colours, Restore and Copy, rename, a draft
scripts/macos/ui-script.sh scripts/macos/ui/outline.json        # the outline in the side column: real clicks jump the editor and the preview, the mark follows the scroll (real wheel events) and the page, keys, folds, divider, notes mode
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/outline-big.json   # 1000 headings: main-thread cost of each kind of update (under 10 ms but one rare shape)
```

UI scripts and their steps: [scripts/macos/ui/README.md](scripts/macos/ui/README.md).

Generated and gitignored: `apps/macos/Frameworks/`, `apps/macos/Sources/MarkdownCore/`, `build/`, `target/`.

`UI_BUILD=/some/dir scripts/macos/ui-script.sh ...` (and `ui-big-focus.sh`) builds and runs `/some/dir/Markdown.app`
instead of `build/Markdown.app`, so a copy someone is using is left alone.

## Side Column

View > Show Outline (⌃⌘O) and View > Show History (⌃⌘H) share one column on the right: each shows its pane, switches to it when the other is showing, and hides the column when its own pane is what shows. It is there in every layout (Preview too), beside the notes sidebar when
that is on (neither makes the window larger). It has a segmented header at its top, the system's small segmented control
(Outline | History), and one content area that holds the outline's view or the history's: the pane not showing is not
alive (it is made when selected and freed when another takes its place), and switching never changes the width. One width
(260 points to start, 200 to 480, dragged by the divider, remembered per window and as the default for new ones) and one
toggle. View > Show History (⌃⌘H) shows the column with History selected, and hides it when History is what it already shows
(as ⌃⌘O does; ⌥⌘H is Hide Others). The column comes back on the pane it had. A click on a segment is remembered per window and as the
default pane; Settings has "Show side column in new windows" and "Side column starts on" (an outline width or an
"outline on by default" stored by an earlier version is read once as the start of the new settings). The title over the
editor ends at the column's left edge whichever pane shows.

The **outline** lists ATX and setext headings, in lists and quotes too, with their inline markup stripped (never what only
looks like a heading inside code or HTML), indented by level with a disclosure triangle per level. The marked entry is where
the reader is, **not the caret**: the heading at, or the last one above, the first visible line of the editor (a dozen points
under the title bar's edge count as the top, so a heading just under the bar is the one), updated once per display refresh
as the editor scrolls and when the headings or the layout change, in Editor and Split; in the Preview layout, the
heading at the top of the page. It is kept in view without taking the keyboard. A click, or Return on the selected row,
moves the caret there, marks the entry and scrolls the editor so the heading is at the top (in the middle with focus centring
on), and the preview to the same heading by its source line; the arrow keys move through the list and fold. It comes from the
core (`Document::outline()`, built from the blocks the analysis already has) and is asked for a quarter of a second after
the last analysis (typing only moves a timer). The history pane is described under History.

## Title

The title over the editor is the app's own (`TitlebarTitleView`): the file name and, while there is an edit not yet
written, "— Edited", centred over the editor's pane (from the sidebar's right edge to the side column's left edge, in
every layout, following divider drags, the column and the window), in the system's title font, middle-truncated, and fading
with the title bar. AppKit's own title views are kept hidden; the window's `title` and `representedURL` stay set for the
Dock, Mission Control and VoiceOver. There is no document icon. A double-click on the name renames the document (File >
Rename, as AppKit's title did), a Command-click shows the folders the file is in (each opens in the Finder), and the rest
of the row drags and zooms the window. What the icon gave is gone: dragging the file from the title bar.
"Edited" follows the document's own state: AppKit's title kept it after every autosave in place (the change count is
cleared by `updateChangeCount(withToken:for:)`, which never reaches `updateChangeCount(_:)` or the window's flag).

## Notes mode

View > Notes Mode (⌃⌘L) puts a sidebar beside the editor in the window; the app is otherwise unchanged
(a window that never used it is the same views it always was). Turn it on for new windows in Settings. Every window has
its own sidebar state; a window opened from another's sidebar starts with a copy of it.

- **The library** is a folder (by default `~/Documents/Markdown Notes`, made from the sidebar's first-use invitation, or any
  folder: Library > Choose Library Folder…) plus any folders added with Library > Add Folder…, each remembered as a
  security-scoped bookmark. Notes are `.md`, `.markdown`, `.mdown` and `.txt`; other files are listed greyed and open in
  their own app; hidden files, `node_modules`, `.git` and anything over 4 MB are left out. The Rust core indexes them
  (titles, tags, wikilinks, search, backlinks); the shell reads and watches the folders (FSEvents) off the main thread.
- **Sidebar**: search (⇧⌘F; Escape clears) replaces the tree with ranked hits and snippets; roots as folder trees,
  sorted by name or modified time (View > Sort Notes); Tags with counts, several selected filter with AND. A click opens
  the note in the window, replacing its document (saved and snapshotted first); Command-click opens it in a window of
  its own; a note that is open in a window already brings that window forward. Return
  renames, ⌘⌫ moves to the Trash (never unlinks), drag moves, files dropped from Finder are copied in; the context
  menu has New Note, New Folder, Rename, Duplicate, Reveal in Finder. Renaming a note that others link to asks "Update
  N links in M notes?" and rewrites the links (undoable in each open document). Backlinks (⌥⌘B) is a panel under the
  list for the front document.
- **Quick Open** (⇧⌘O): type a few letters of a title or path, arrow, Return (Command-Return opens a window).
- **Daily notes and templates**: File > Today's Note (⌃⌘N) opens `Daily/YYYY-MM-DD.md`, made once from
  `Templates/Daily.md`; File > New from Template (⇧⌘N chooses) fills `{{date}}`, `{{time}}`, `{{title}}`, `{{today}}`
  and puts the caret at `{{cursor}}`. Folder names and the file name format are in Settings.
- **Wikilinks and tags**: `[[Title]]`, `[[Title|label]]`, `[[Title#Heading]]` and `#tag` are styled in the editor;
  ⌘-click replaces the window's document with the note (⌘⌥-click opens it in a
  window of its own), or offers to make it beside the current one; in the preview a click does the same. Without notes mode, a wikilink opens the note beside the document.

- **A history to try**: `examples/History Demo.md` is a short note meant for View > History (⌃⌘H). With the app quit, run
  `scripts/macos/seed-history-demo.sh` (`UI_BUILD=dir` for another build): the app writes eight versions of it, spread
  over ten days and with every reason and two messages, into the real history folder under the key a normal open derives,
  and exits. Running it again records nothing new.

## One document per window

There are no tabs: a window shows one document, the title and its "Edited" mark are in the title bar, and the
window refuses tabbing (no Merge All Windows, no tab items anywhere). A note chosen in the sidebar, a backlink, a
wikilink, Quick Open, Today's Note, a template or a link in the preview replaces the window's document, which is written
and snapshotted first; the new document takes the old one's place and size, its workspace (so the sidebar is as it was),
its layout and mode, and its column. Command-click (⌘-Return in Quick Open, ⌘⌥-click on a wikilink) opens a new window instead.

## Reopening and quitting

The app keeps its own record of its windows (`~/Library/Application Support/Markdown/session.json`, written a moment
after anything in it changes and once more on quit) and puts them back at every launch, whatever the system's "Close
windows when quitting" says: each window's document (a bookmark, so a moved file is found), frame and screen, full
screen, layout, focus mode, Notes Mode with its folder, selection, filters, sort, open folders and
sidebar width and scroll, the side column (shown, pane, width), the caret and the scroll position, the order of the
windows and which one was key. A file that has gone is skipped (noted in the log, no dialog). An untitled document comes
back untitled with its text, and quitting never asks to save it. Settings > "Reopen documents at launch" (on) turns it
off. Quitting (⌘Q, the Dock, logout) with a window open asks "Quit Markdown?" with Quit and Cancel and "Do not ask
again"; Settings > "Ask before quitting" (on) is the same setting. With no window open the app quits at once.

## Autosave

A titled document is written 2 seconds after the last keystroke, and when it leaves its window (closing, being
replaced, quitting), through NSDocument's own autosave (`autosavesInPlace`: the same coordinated, asynchronous write
as ⌘S, over the file itself); typing that never pauses is written by NSDocument's timer after 15 s at the latest. The
undo stack is never touched by a write, the window never shows the edited dot and closing asks nothing. File > Save
(⌘S) saves now and takes a snapshot of its own. An untitled document is written into the library's `Drafts` folder as
`Untitled N.md` when a library exists (it becomes titled and shows in the sidebar); without a library it asks, as it
always did, when it closes. If another app wrote the file meanwhile (its date is newer than what this window last
read or wrote), the text here is snapshotted (with a message, so it is kept for good), the file is read again and a
bar under the title bar says so, with a Show History button; the other app's version is never overwritten.

## History

Every titled document has a history of snapshots, kept by the core (`markdown_core::history`, the same on every
platform) in `~/Library/Application Support/Markdown/history`: one folder per document with an `index.json` and one
`<sha256>.md` per distinct text, so a person can recover a text without the app. A snapshot is taken 2 s after the last
keystroke (with the autosave), when a document leaves its window, on ⌘S, on Restore and when a draft is made; nothing is
recorded when the text equals the latest snapshot, and the first snapshot of a session is the text as it was opened. They
are kept for 24 hours, then one per hour for a week, then one per day, at most 10 MB per document, and a snapshot with
a message is never thinned. The key is the note in the library (so a rename or a move keeps the history) or a hash of the
file's path.

View > Show History (⌃⌘H) puts the timeline on the right, in the side column (the History segment; the outline is the
other): versions grouped by day, each with its time, the reason (pause, close, save, restore, draft),
the lines added and removed and its message. A version shows its diff against the text as it is now below the list
(removed lines in the theme's reference colour, added lines in its AI colour, both muted); Restore records the text as
it is, then puts the version's text in as one undoable edit, "Restore Version"; Copy puts the version's text on the
clipboard. The panel follows snapshots as they are taken.

## Code in the editor

Fenced code is highlighted in the editor, in the languages the preview knows and the theme's `[syntax]` colours; a small badge at the top right of a block names its language and, clicked, offers the others (the choice rewrites the info string, one undo step).

## Icons

The app icon is drawn outside this repository; `assets/` holds what it ships:

- `assets/macOS-11-to-15/AppIcon.icns` (with its iconset, a 1024 px PNG and the SVG it was drawn from) is the
  icon for macOS 11 to 15. `bundle.sh` copies it into the app as `Contents/Resources/Markdown.icns`
  (`CFBundleIconFile`).
- `assets/macOS-26-Icon-Composer-layers/` holds the two layers of the Liquid Glass icon for macOS 26: a full-bleed
  `background.png` and `glyph.png` (the "#m" set in IBM Plex Mono, SIL OFL, credited in Acknowledgements).
- `assets/Markdown.icon` is the Icon Composer package made from those two layers: `icon.json` (the glyph is
  glass, with a neutral shadow and translucency; the background is a plain layer under it) and copies of the
  two PNG layers in `Assets/`.

`bundle.sh` compiles the package whenever it is there, the equivalent of:

```sh
xcrun actool assets/Markdown.icon --compile OUT --app-icon Markdown --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 --output-partial-info-plist OUT/partial.plist --notices --warnings --errors
```

and puts `OUT/Assets.car` into the app beside `Markdown.icns`, with `CFBundleIconName` = `Markdown` added to
its Info.plist. macOS 26 draws the icon from `Assets.car`; earlier systems ignore `CFBundleIconName` and use the
`.icns`. Any warning, error or SVG-renderer complaint from actool fails the build. actool needs Xcode 26 (not
only the command-line tools). Documents have no icon of their own: Finder shows the system's plain document icon
for them. `verify-bundle.sh` checks both icons are there and complete.

To change the macOS 26 icon, open `assets/Markdown.icon` in Icon Composer (Xcode > Open Developer Tool), edit,
and save it in place; or replace a layer's SVG in `assets/Markdown.icon/Assets/`. Without the package, a build
uses the `.icns` alone, and `verify-bundle.sh` (so a release) refuses it.

## Releasing

```sh
CODESIGN_IDENTITY='Developer ID Application: Steve Kaznak (VLC2KZKNBH)' NOTARIZE_PROFILE=notary scripts/macos/release.sh
```

That one command: refuses a dirty working tree (`--allow-dirty` overrides), runs the Rust and Swift test suites
(`--skip-tests`), checks that `Acknowledgements.md` is current, builds the core and the app for arm64 and x86_64
(`bundle.sh --release --universal`, signed with the identity, hardened runtime, secure timestamp), verifies the bundle
(`verify-bundle.sh`: the exact file list, both slices with a minimum OS of 14.0, no UI-harness code, signature,
hardened runtime, Developer ID authority), wraps it in `build/Markdown-<version>.dmg` (`make-dmg.sh`, signed),
submits the image to the notary service and waits, reads the verdict from the JSON (an Invalid verdict still exits 0)
and prints the notary log if it is not Accepted, staples and validates the ticket, runs `spctl` on the image and on
the app inside a read-only mount of it, and prints paths, sizes, SHA-256 and the verdicts. Without `NOTARIZE_PROFILE`
the image is signed but not notarized, and says so. `NOTARIZE_PROFILE` is a `xcrun notarytool store-credentials`
profile name; nothing secret is printed.

Before the real run, `security find-identity -v -p codesigning` must list exactly one `Developer ID Application`
identity of that name (otherwise pass its SHA-1 hash as `CODESIGN_IDENTITY`), and the notary profile must exist
(`xcrun notarytool history --keychain-profile notary` lists past submissions). The script refuses a shallow clone
(the build number would be wrong), waits at most `NOTARIZE_TIMEOUT` seconds (default 7200) for the verdict and then
prints how to finish by hand (`notarytool wait`, `stapler staple`), and accepts the Gatekeeper assessments only when
they say `source=Notarized Developer ID`.

`scripts/macos/tests/release-pipeline.sh` tests that control flow without Apple (about 15 minutes): it copies the
working tree to a folder whose path has spaces, runs a real dry run there from another directory, and then the
real path with stand-ins on `PATH` (`scripts/macos/tests/stubs`: a fake identity that signs ad-hoc, a notary
service that answers Accepted, Invalid with exit status 0, malformed or empty output, an error, "In Progress", or
never; a stapler that fails; Gatekeeper rejecting the image or accepting it without its notarization). Only
Accepted with a notarized assessment may succeed, nothing may be stapled otherwise, and no image may stay mounted.
Dirty trees, shallow clones and missing, ambiguous or wrong identities must be refused before anything is built.

`scripts/macos/release.sh --dry-run --allow-dirty --skip-tests` runs everything except Developer ID signing and
notarization: it signs ad-hoc, contacts no one, skips the Gatekeeper assessments (an ad-hoc build fails them by
design) and says so at every step. Its image must not be shipped.

The version is `CFBundleShortVersionString` in `apps/macos/Resources/Info.plist`; the build number is the number of
commits, set by `bundle.sh`. The app needs no entitlements (see the comment in `Markdown.entitlements`).
