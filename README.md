# markdown

A native macOS Markdown editor on a shared Rust core. See [PLAN.md](PLAN.md).

Requirements: Xcode 26+, Rust (rustup) with `aarch64-apple-darwin` and `x86_64-apple-darwin` targets. No other tools needed (UniFFI's bindgen is a workspace binary).

```sh
# Rust tests (spans, markup, offsets, dirty ranges, proptest, CommonMark spec, insta snapshots,
# an oracle against pulldown-cmark's event stream, editing commands, tables, bare-URL autolinks, themes,
# Live-mode concealment, focus ranges, part-of-speech units, authorship: run arithmetic and the
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
# cargo test -p markdown-core --test authorship -- --ignored spec_readme    # the format's own spec README (fetched, not vendored) still verifies
# cargo test --release -p markdown-core --test perf -- --ignored --nocapture         # 1 MB timing, HTML rendering included
# RENDER_FUZZ_CASES=50000 cargo test --profile fuzz -p markdown-core --test render   # render fuzzing, sanitizer soup checked by a browser-faithful tokenizer
# RENDER_DIFF_CASES=1000000 cargo test --profile fuzz -p markdown-core --test render_diff   # the renderer against pulldown-cmark's own writer, additions normalised away
# cargo test --release -p markdown-core --test perf -- --ignored --nocapture worst_case   # no 1 MB render over 100 ms (highlighting budget)
# cargo test --release -p markdown-core --test robustness -- --ignored --nocapture one_megabyte   # 1 MB worst cases

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
scripts/macos/ui-script.sh scripts/macos/ui/live.json           # Live mode tour -> build/ui/live/
scripts/macos/ui-script.sh scripts/macos/ui/live-look.json      # Live mode by eye: pictures, selections, drop/paste
scripts/macos/ui-script.sh scripts/macos/ui/live-edge.json      # Live mode edge cases
scripts/macos/ui-script.sh scripts/macos/ui/look.json           # the M2 look: the tour in three themes, Settings
scripts/macos/ui-script.sh scripts/macos/ui/focus.json          # focus mode, sentence and paragraph, Source and Live, three themes
scripts/macos/ui-script.sh scripts/macos/ui/syntax.json         # parts-of-speech colours, classes switched off, with focus mode
scripts/macos/ui-script.sh scripts/macos/ui/authorship.json     # Paste As, Mark As, typing in borrowed text, undo, save and reopen; three themes
scripts/macos/ui-script.sh scripts/macos/ui/authorship-mismatch.json  # the keep-or-discard sheet for marks that may be misplaced
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/big.json  # 1 MB typing timings, release build
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/big-live.json   # the same in Live mode
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/threshold.json  # Live mode either side of the whole-text limit
scripts/macos/ui-script.sh scripts/macos/ui/preview.json        # Split and Preview layouts: three themes, typing, scroll sync both ways, links, fonts, snapshots of the web view
scripts/macos/ui-script.sh scripts/macos/ui/preview-export.json # PDF export (Dark, Sepia; preview hidden, split, preview): pages, text, picture, white page, margins
scripts/macos/ui-script.sh scripts/macos/ui/preview-edge.json   # pictures of every kind in editor and preview alike, links of every kind, a hostile document, themes and fonts, untitled
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/preview-big.json   # 1 MB in Split: typing with the preview closed and open, preview latency, main-thread cost of an update (≤ 16 ms)
scripts/macos/ui-script.sh scripts/macos/ui/soak.json           # everything together at random, checked after every step
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/drift.json  # a long Live session at 1 MB: cost per key and per jump must not grow (about 9 minutes)
scripts/macos/ui-big-focus.sh                                   # 1 MB, release: focus, syntax and authorship off vs on, and a save
scripts/macos/ui-script.sh scripts/macos/ui/acceptance.json     # 1.0 end to end: a document made with menus and typing, saved, exported, copied, reopened
scripts/macos/ui-script.sh scripts/macos/ui/pictures.json       # pictures at their declared resolution; Up and Down keep their column through one
scripts/macos/ui-script.sh scripts/macos/ui/polish.json         # code panels in lists and quotes, pictures at every resolution in editor, preview and PDF
scripts/macos/ui-script.sh scripts/macos/ui/first-run.json      # the first window, the scroll limit, Help and Acknowledgements
scripts/macos/ui-script.sh scripts/macos/ui/lifecycle.json      # 50 documents opened and closed: everything freed, memory flat
scripts/macos/ui-script.sh scripts/macos/ui/robust.json         # 10 MB, a 5 MB line, binary, changed on disk, read-only, odd names, empty, mixed endings
scripts/macos/ui-script.sh scripts/macos/ui/edge.json           # tiny window, documents of only front matter/table/picture/nothing, tabs, everything on at once
scripts/macos/ui-script.sh scripts/macos/ui/scroll-limits.json  # the editor's scroll limits in every layout, resized, with the find bar
scripts/macos/ui-script.sh scripts/macos/ui/notes.json          # notes mode: sidebar, tabs, Option-click, search, tags, backlinks within a second, tab-switch measurement
scripts/macos/ui-script.sh scripts/macos/ui/notes-files.json    # new note and folder, rename with link updates and undo, drag, Trash, templates, today's note
scripts/macos/ui-script.sh scripts/macos/ui/notes-links.json    # wikilinks: Cmd-click and preview clicks, plain mode and notes mode, a link to nothing
scripts/macos/ui-script.sh scripts/macos/ui/quick-open.json     # the palette: fuzzy on titles and paths, arrows, Return, Option-Return, Escape
```

UI scripts and their steps: [scripts/macos/ui/README.md](scripts/macos/ui/README.md).

Generated and gitignored: `apps/macos/Frameworks/`, `apps/macos/Sources/MarkdownCore/`, `build/`, `target/`.

`UI_BUILD=/some/dir scripts/macos/ui-script.sh ...` (and `ui-big-focus.sh`) builds and runs `/some/dir/Markdown.app`
instead of `build/Markdown.app`, so a copy someone is using is left alone.

## Notes mode

View > Notes Mode (⌃⌘L) puts a sidebar beside the editor in every window of a tab group; the app is otherwise unchanged
(a window that never used it is the same views it always was). Turn it on for new windows in Settings.

- **The library** is a folder (by default `~/Documents/Markdown Notes`, made from the sidebar's first-use invitation, or any
  folder: Library > Choose Library Folder…) plus any folders added with Library > Add Folder…, each remembered as a
  security-scoped bookmark. Notes are `.md`, `.markdown`, `.mdown` and `.txt`; other files are listed greyed and open in
  their own app; hidden files, `node_modules`, `.git` and anything over 4 MB are left out. The Rust core indexes them
  (titles, tags, wikilinks, search, backlinks); the shell reads and watches the folders (FSEvents) off the main thread.
- **Sidebar**: search (⇧⌘F; Escape clears) replaces the tree with ranked hits and snippets; roots as folder trees,
  sorted by name or modified time (View > Sort Notes); Tags with counts, several selected filter with AND. A click opens
  a note as a tab of the group (or brings its tab forward); Option-click replaces the current tab's document. Return
  renames, ⌘⌫ moves to the Trash (never unlinks), drag moves, files dropped from Finder are copied in; the context
  menu has New Note, New Folder, Rename, Duplicate, Reveal in Finder. Renaming a note that others link to asks "Update
  N links in M notes?" and rewrites the links (undoable in each open document). Backlinks (⌥⌘B) is a panel under the
  list for the front document.
- **Quick Open** (⇧⌘O): type a few letters of a title or path, arrow, Return (Option-Return replaces the tab).
- **Daily notes and templates**: File > Today's Note (⌃⌘N) opens `Daily/YYYY-MM-DD.md`, made once from
  `Templates/Daily.md`; File > New from Template (⇧⌘N chooses) fills `{{date}}`, `{{time}}`, `{{title}}`, `{{today}}`
  and puts the caret at `{{cursor}}`. Folder names and the file name format are in Settings.
- **Wikilinks and tags**: `[[Title]]`, `[[Title|label]]`, `[[Title#Heading]]` and `#tag` are styled in the editor
  (Live mode conceals the brackets); ⌘-click opens the note, or offers to make it beside the current one; in the preview
  a click does the same. Without notes mode, a wikilink opens the note beside the document.

## Icons

The app icon is drawn outside this repository; `assets/` holds what it ships:

- `assets/macOS-11-to-15/AppIcon.icns` (with its iconset, a 1024 px PNG and the SVG it was drawn from) is the
  icon for macOS 11 to 15. `bundle.sh` copies it into the app as `Contents/Resources/Markdown.icns`
  (`CFBundleIconFile`).
- `assets/macOS-26-Icon-Composer-layers/` holds the two layers of the Liquid Glass icon for macOS 26: a full-bleed
  `background.svg` and a flat white `glyph.svg` (Fira Mono Bold outlines, SIL OFL, credited in Acknowledgements).
- `assets/Markdown.icon` is the Icon Composer package made from those two layers: `icon.json` (the glyph is
  glass, with a neutral shadow and translucency; the background is a plain layer under it) and the two SVGs in
  `Assets/`. Its `background.svg` is the layer's file without two filter definitions the drawing never uses,
  which the system's SVG renderer cannot read (it logged an error for each).

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
