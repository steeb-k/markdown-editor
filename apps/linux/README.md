# Linux shell (not built yet)

A GTK4/libadwaita editor (gtk4-rs) will reuse `markdown-core` directly, without UniFFI.
The core must therefore keep this contract:

- No Apple types or assumptions anywhere in `markdown-core`.
- `Utf32` offsets work as well as `Utf16` (both are tested); GtkTextBuffer counts Unicode scalars.
- Concealment is expressed as ranges, which map onto `GtkTextTag:invisible`.
- Decorations are abstract kinds (bullet, checkbox, rule, image), not glyphs.
- POS tagging is a shell-supplied service; the core only supplies prose ranges.

What a GTK shell writes for the focus tools, given what the core already does:

- **Focus mode**: `Document::selection_state(selection, window, conceal, Some(scope))` after each
  selection change (one call; `focus` holds the ranges to keep at full strength, empty means dim
  everything). Dim by applying a `GtkTextTag` with the theme's `focus_dim` foreground to the
  complement; the shell has no sentence or paragraph logic of its own.
- **Syntax highlighting**: `Document::pos_units(window)` gives one unit per block (its prose
  pieces and where they are set off from each other). Join a unit's pieces as `PosUnit` says,
  run the tagger on the text, turn its words into `PosTag`s (class mapping below, offsets in the
  joined text) and call `PosUnit::map_tags` to get document ranges, one tag per piece for a
  word cut by markup. Cache the result by the joined text (plus the pieces' layout and the
  language) as ranges relative to the unit, so scrolling and unrelated edits never tag again.
  Colour with the theme's `pos_*` roles in a tag lower in priority than the focus dimming.
- The five classes are noun, verb, adjective, adverb, conjunction. macOS maps `NLTag.noun`
  (names included), `.verb`, `.adjective`, `.adverb`, `.conjunction` and leaves pronouns,
  determiners, prepositions, particles, numbers, interjections and everything else uncoloured.

- **Authorship** is its own small type, `markdown_core::authorship::Authorship`: pure range arithmetic
  in the buffer's unit (`Utf32` for GTK), no parsing, cheap enough to live on the main thread next
  to the `GtkTextBuffer` so undo is synchronous. Keep it in step from the buffer's
  `insert-text` / `delete-range` signals with `edit(range, inserted_len, attribution)` (`Typed(me)`
  for typing and plain paste, `As(author)` for Paste As, `Inherit` or `edit_replacing(range, old,
  new, Inherit)` for edits the core's commands compute) and take an `AuthorshipSnapshot` before each
  undoable change. Colour AI and Reference runs (`runs(None)`) with `GtkTextTag`s using the theme's
  `author_ai` / `author_reference`, below focus dimming and parts of speech. On open, call
  `split_annotations(file_text)` (the file as read, line endings untouched), show `body`, build the
  attribution with `Authorship::from_annotations(body_with_lf, annotations, encoding, name)`, call
  `set_origin(body, raw_tail, ending)`, and on `HashMismatch` / `Malformed` ask Keep or Discard
  before the buffer is editable. On save write `body` then `file_tail(text, ending)`.

Open question: which part-of-speech tagger Linux uses (macOS uses NLTagger).
