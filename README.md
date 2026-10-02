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

# Regenerate the icons (CoreGraphics; Markdown.icns and MarkdownDocument.icns in apps/macos/Resources)
swift scripts/macos/make-icons.swift build/icons --icns && cp build/icons/*.icns apps/macos/Resources/
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
```

UI scripts and their steps: [scripts/macos/ui/README.md](scripts/macos/ui/README.md).

Generated and gitignored: `apps/macos/Frameworks/`, `apps/macos/Sources/MarkdownCore/`, `build/`, `target/`.

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

`scripts/macos/release.sh --dry-run --allow-dirty --skip-tests` runs everything except Developer ID signing and
notarization: it signs ad-hoc, contacts no one, skips the Gatekeeper assessments (an ad-hoc build fails them by
design) and says so at every step. Its image must not be shipped.

The version is `CFBundleShortVersionString` in `apps/macos/Resources/Info.plist`; the build number is the number of
commits, set by `bundle.sh`. The app needs no entitlements (see the comment in `Markdown.entitlements`).
