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
  pieces and where they are set off from each other), or several for a block with more than about
  12 KB of prose, cut at places an edit elsewhere does not move. Join a unit's pieces as `PosUnit` says,
  run the tagger on the text, turn its words into `PosTag`s (class mapping below, offsets in the
  joined text) and call `PosUnit::map_tags` to get document ranges, one tag per piece for a
  word cut by markup. Cache the result by the joined text (plus the pieces' layout and the
  language) as ranges relative to the unit, so scrolling and unrelated edits never tag again.
  Colour with the theme's `pos_*` roles in a tag lower in priority than the focus dimming. The macOS
  shell tags a unit of 100 or more characters that its recognizer is at least 90% sure is in another
  (supported) language in that language, and otherwise in the document's.
- The five classes are noun, verb, adjective, adverb, conjunction. macOS maps `NLTag.noun`
  (names included), `.verb`, `.adjective`, `.adverb`, `.conjunction` and leaves pronouns,
  determiners, prepositions, particles, numbers, interjections and everything else uncoloured.

- **Authorship** is its own small type, `markdown_core::authorship::Authorship`: pure range arithmetic
  in the buffer's unit (`Utf32` for GTK), no parsing, cheap enough to live on the main thread next
  to the `GtkTextBuffer` so undo is synchronous. Keep it in step from the buffer's
  `insert-text` / `delete-range` signals with `edit(range, inserted_len, attribution)` (`Typed(me)`
  for typing, plain paste, find-and-replace, spelling corrections and dropped files, `As(author)` for
  Paste As, `Inherit` or `edit_replacing(range, old, new, Inherit)` for edits the core's commands
  compute; a replacement of several ranges at once is one `edit` per range, the last range first) and take an `AuthorshipSnapshot` before each
  undoable change. Colour AI and Reference runs (`runs(None)`) with `GtkTextTag`s using the theme's
  `author_ai` / `author_reference`, below focus dimming and parts of speech. On open, call
  `split_annotations(file_text)` (the file as read, line endings untouched), show `body`, build the
  attribution with `Authorship::from_annotations(body_with_lf, annotations, encoding, name)`, call
  `set_origin(body, raw_tail, ending)`, and on `HashMismatch` / `Malformed` ask Keep or Discard
  before the buffer is editable. On save write `body` then `file_tail(text, ending)`.

- **Preview and export** are core calls, so a GTK shell hosts a web view and nothing more:
  - `Document::render_html(&RenderOptions { source_lines: true, standalone: true, style: Some(PreviewStyle { theme, typography }), .. })`
    is a complete HTML5 page (charset, viewport, title, the stylesheet); without `standalone` it is the
    body, for replacing a running page's content. `render_html_fragment(range, options)` renders the
    whole blocks a selection touches (an empty range: everything); with `sanitize: true` raw HTML is
    filtered, which is what the clipboard wants. `preview_css(theme, typography)` is the stylesheet
    alone, for a theme change without a reload. Run the render on the worker thread that owns the
    `Document`, debounced after edits (short for small texts, longer for large ones), and keep at most one in flight.
  - Show it in **WebKitGTK with page JavaScript off** (`WebKitSettings:enable-javascript = false`): a
    document's raw HTML passes through unchanged and is not trusted. Run your own script (scroll sync,
    in-place body replacement) with `webkit_web_view_run_javascript` / a user script in an isolated
    world (`webkit_user_content_manager`), which JavaScript-off does not stop. Replace the content of
    `<main id="md">` instead of reloading, so the scroll position survives.
  - `source_lines` puts `data-line="N"` (0-based first source line) on every block-level element: scroll
    sync is "line of the editor's top visible text" to the nearest preceding element and back, interpolating
    between the elements either side (see `ScrollSync` in the macOS shell; the same few lines in JS).
  - Local pictures: serve document-relative files through a custom URI scheme (`webkit_web_context_register_uri_scheme`)
    that reads through your file-access seam rather than `file:`; the base URI of the page is the scheme root.
  - PDF and printing: load the standalone page into an offscreen web view and use `WebKitPrintOperation`
    (the page's `@media print` section makes it light, paginated, links without URLs). Syntax highlighting
    is class-based (`s-keyword`, ...; syntect with its pure-Rust regex backend, no C), coloured by the
    stylesheet. `highlight::warm_up()` loads the syntaxes (about a millisecond; the first block of each
    language compiles its patterns), call it from a worker thread before the first preview.
  - The core's text never holds the authorship annotation block, so a preview rendered from it cannot show it.

Open question: which part-of-speech tagger Linux uses (macOS uses NLTagger).
