# markdown

A native macOS Markdown editor on a shared Rust core. See [PLAN.md](PLAN.md).

Requirements: Xcode 26+, Rust (rustup) with `aarch64-apple-darwin` and `x86_64-apple-darwin` targets. No other tools needed (UniFFI's bindgen is a workspace binary).

```sh
# Rust tests (spans, markup, offsets, dirty ranges, proptest, CommonMark spec, insta snapshots,
# an oracle against pulldown-cmark's event stream, editing commands, tables, bare-URL autolinks, themes,
# Live-mode concealment)
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
# cargo test --release -p markdown-core --test perf -- --ignored --nocapture         # 1 MB timing
# cargo test --release -p markdown-core --test robustness -- --ignored --nocapture one_megabyte   # 1 MB worst cases

# Build the core: static lib + Swift bindings + XCFramework (host arch, debug)
scripts/build-core.sh                 # or --release, or --universal (arm64+x86_64, release)

# Swift build and tests (after build-core.sh)
cd apps/macos && swift build && swift test

# Assemble and ad-hoc sign build/Markdown.app (runs build-core.sh and swift build)
scripts/macos/bundle.sh               # or --release, or --universal
open build/Markdown.app

# Real signing: CODESIGN_IDENTITY="Developer ID Application: ..." scripts/macos/bundle.sh --release

# Drive the real app from a JSON script (no Accessibility permission needed): snapshots + log.json
scripts/macos/ui-script.sh scripts/macos/ui/smoke.json          # -> build/ui/smoke/
scripts/macos/ui-script.sh scripts/macos/ui/live.json           # Live mode tour -> build/ui/live/
RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/big.json  # 1 MB typing timings, release build
```

UI scripts and their steps: [scripts/macos/ui/README.md](scripts/macos/ui/README.md).

Generated and gitignored: `apps/macos/Frameworks/`, `apps/macos/Sources/MarkdownCore/`, `build/`, `target/`.
