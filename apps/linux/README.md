# Linux shell (not built yet)

A GTK4/libadwaita editor (gtk4-rs) will reuse `markdown-core` directly, without UniFFI.
The core must therefore keep this contract:

- No Apple types or assumptions anywhere in `markdown-core`.
- `Utf32` offsets work as well as `Utf16` (both are tested); GtkTextBuffer counts Unicode scalars.
- Concealment is expressed as ranges, which map onto `GtkTextTag:invisible`.
- Decorations are abstract kinds (bullet, checkbox, rule, image), not glyphs.
- POS tagging is a shell-supplied service; the core only supplies prose ranges.

Open question: which part-of-speech tagger Linux uses (macOS uses NLTagger).
