//! Public value types of the core API.

/// Unit in which every range crossing the API is expressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OffsetEncoding {
    /// UTF-8 bytes.
    Utf8,
    /// UTF-16 code units (`NSString`, JavaScript).
    Utf16,
    /// Unicode scalar values (`GtkTextBuffer`).
    Utf32,
}

/// A half-open range `[start, end)` in the document's [`OffsetEncoding`] unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, PartialOrd, Ord)]
pub struct TextRange {
    pub start: u32,
    pub end: u32,
}

impl TextRange {
    pub const fn new(start: u32, end: u32) -> Self {
        Self { start, end }
    }

    pub const fn len(&self) -> u32 {
        self.end.saturating_sub(self.start)
    }

    pub const fn is_empty(&self) -> bool {
        self.end <= self.start
    }
}

/// What a range of the document is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpanKind {
    /// Whole heading (ATX or setext), markup included.
    Heading { level: u8 },
    Emphasis,
    Strong,
    Strikethrough,
    /// Whole code span, backticks included.
    InlineCode,
    /// Whole code block (fences included for fenced blocks).
    CodeBlock,
    /// Info string of a fenced code block.
    CodeInfo,
    /// Whole link, brackets and destination included.
    Link,
    /// Link destination and title (inline links), label (reference links) or the
    /// URL between the angle brackets (autolinks).
    LinkDestination,
    /// Whole image, `![` through `)`.
    Image,
    /// Whole block quote.
    BlockQuote,
    /// The marker characters only (`-`, `*`, `+`, `1.`, `1)`), not the space after.
    ListMarker { ordered: bool },
    /// `[ ]` or `[x]`.
    TaskMarker { checked: bool },
    /// Whole table.
    Table,
    /// The `|---|---|` line (leading block-quote prefix excluded).
    TableDelimiterRow,
    /// `[^label]` reference. Its `[^` and `]` are `Markup`; the label is not.
    FootnoteReference,
    /// Whole footnote definition. Its `[^` and `]:` are `Markup`; the label is not.
    FootnoteDefinition,
    /// Whole YAML front matter block, delimiters included.
    FrontMatter,
    ThematicBreak,
    /// Raw HTML, block or inline.
    Html,
    /// Trailing double space (or backslash) plus the newline.
    HardBreak,
    /// Whole wikilink, `[[Title|label]]`. Its `[[`, `]]`, the `|` with what precedes it (target
    /// and `#heading`) and, without a label, the `#heading` are `Markup` owned by the wikilink,
    /// so Live mode shows the label (or the target) alone. Found in runs of plain text only,
    /// never inside code, links, images, HTML or front matter.
    Wikilink,
    /// Inline tag, `#` included. Never on a heading line, nor inside anything a wikilink
    /// cannot be in.
    Tag,
    /// Syntax characters; dimmed in Source mode, concealable in Live mode.
    Markup,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub range: TextRange,
    pub kind: SpanKind,
}

/// A wikilink and where it points (see [`crate::Document::wikilink_at`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WikilinkRef {
    /// The whole `[[...]]`.
    pub range: TextRange,
    /// As written, without surrounding blanks; empty for a link into the same note
    /// (`[[#Heading]]`).
    pub target: String,
    pub heading: Option<String>,
    pub label: Option<String>,
}

/// Leaf block kinds. Containers (block quote, list, list item, footnote
/// definition) only contribute to [`Block::depth`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Paragraph,
    Heading,
    CodeBlock,
    Table,
    HtmlBlock,
    ThematicBreak,
    FrontMatter,
}

/// A leaf block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Block {
    pub kind: BlockKind,
    /// Without the trailing line terminator.
    pub range: TextRange,
    /// 0-based line of the block's first character. Line terminators are `\n`,
    /// `\r\n` and lone `\r`.
    pub line: u32,
    pub heading_level: Option<u8>,
    /// Number of enclosing block quotes, list items and footnote definitions.
    pub depth: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageRef {
    /// The whole element, `![alt](dest "title")`.
    pub range: TextRange,
    pub destination: String,
    pub alt: String,
    pub title: Option<String>,
    /// The image is the sole content of its paragraph.
    pub standalone: bool,
}

/// How far a markup span's visibility is tied to the selection (used by Live mode).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MarkupScope {
    /// Revealed when the selection touches the owning inline element.
    Inline,
    /// Revealed when the selection touches the owning line.
    Line,
    /// Revealed when the selection touches the owning block.
    Block,
}

/// A `Markup` span with the information Live mode needs to decide whether to hide it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MarkupSpan {
    pub range: TextRange,
    /// The inline element (Inline), the line (Line) or the block (Block) it belongs to.
    pub owner: TextRange,
    pub scope: MarkupScope,
    /// Inside a table: never concealed.
    pub in_table: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Update {
    /// Range of the NEW text outside which the spans are identical to before
    /// (after shifting by the edit's length delta). Whole lines, always includes
    /// the inserted text.
    pub dirty: TextRange,
    pub revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditError {
    /// An endpoint is beyond the end of the document.
    OutOfBounds,
    /// `start > end`.
    InvertedRange,
    /// An endpoint falls inside a code point (e.g. between UTF-16 surrogates).
    NotOnCodePointBoundary,
    /// The resulting document would be longer than `u32::MAX` units.
    TooLarge,
}

impl std::fmt::Display for EditError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            EditError::OutOfBounds => "range is out of bounds",
            EditError::InvertedRange => "range start is after its end",
            EditError::NotOnCodePointBoundary => "range endpoint is inside a code point",
            EditError::TooLarge => "document would exceed the maximum length",
        })
    }
}

impl std::error::Error for EditError {}

// ----- editing commands ---------------------------------------------------------------------

/// A text change computed by an editing command. Commands never mutate the document: the
/// shell applies the edit through its own text system (so undo, IME and accessibility keep
/// working), selects `selection`, then calls [`crate::Document::replace`] with the same range
/// and replacement.
///
/// `range` is in the text the command was asked about; `selection` is in the text *after*
/// the edit. Edits are minimal: text common to the old and the new version is not part of
/// `range`/`replacement`. An edit with an empty `range` and an empty `replacement` is a
/// *selection change only* (the text stays as it is; e.g. moving to the next table cell).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextEdit {
    pub range: TextRange,
    pub replacement: String,
    pub selection: TextRange,
}

/// Which list a line belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ListKind {
    #[default]
    None,
    Bullet,
    Ordered,
    Task,
}

/// Column alignment of a table column (`:---`, `:---:`, `---:`, `---`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ColumnAlignment {
    #[default]
    None,
    Left,
    Center,
    Right,
}

/// An editing command for [`crate::Document::format`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormatCommand {
    Strong,
    Emphasis,
    Strikethrough,
    InlineCode,
    /// Wrap the selection as `[selection](url)`, or remove the link around the caret.
    Link,
    /// Insert `![alt](destination)`. An empty `alt` falls back to a single-line selection.
    Image { destination: String, alt: String },
    /// Insert `[text](destination)` in place of the selection, caret after it (a dropped file).
    /// An empty `text` falls back to a single-line selection, then to the destination.
    LinkTo { destination: String, text: String },
    /// ATX heading level 0 (none) to 6 on the selected lines; the same level again removes it.
    Heading { level: u8 },
    BlockQuote,
    BulletList,
    OrderedList,
    TaskList,
    CodeBlock,
}

/// What is active at the selection, for the toolbar's lit buttons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FormatState {
    pub strong: bool,
    pub emphasis: bool,
    pub strikethrough: bool,
    pub inline_code: bool,
    pub link: bool,
    /// 0 when the line is not a heading.
    pub heading_level: u8,
    pub in_quote: bool,
    pub list: ListKind,
    pub in_code_block: bool,
    pub in_table: bool,
}

/// A table helper for [`crate::Document::table_command`].
///
/// Every command except `Insert` needs the start of the selection inside a table (its lines,
/// container prefix included; the end of the last line counts) and returns one edit that also
/// re-aligns the whole table: each column padded to its widest cell in display columns, one
/// blank inside the pipes, leading and trailing pipes, alignment colons in the delimiter row,
/// any container prefix (`> `, indentation) kept. Where the selection lands is documented per
/// command; unless said otherwise it is a caret at the start of a cell's content.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableCommand {
    /// A header row, a delimiter row and `rows` (at most 1000) empty body rows, on their own
    /// lines with a blank line around them where needed. `columns` is clamped to 1..=100.
    /// Put at the caret's line when that is blank, before the line when the caret is at its
    /// start, otherwise after it (or after the table, if the caret is in one). The caret goes
    /// into the first header cell.
    Insert { rows: u32, columns: u32 },
    /// `None` on the header and delimiter rows. Caret in the new row, same column.
    AddRowAbove,
    /// On the header or delimiter row the new row becomes the first body row.
    AddRowBelow,
    /// Caret in the new column, same row (the header row if on the delimiter row).
    AddColumnLeft,
    AddColumnRight,
    /// `None` on the header and delimiter rows. Caret in the row that took its place (the one
    /// before it if it was last; the header if no body row is left), same column.
    DeleteRow,
    /// `None` for the last remaining column.
    DeleteColumn,
    /// Set the alignment of the caret's column; the selection is carried through unchanged.
    SetAlignment(ColumnAlignment),
    /// Select the content of the next cell (a caret if it is empty); from the last cell a body
    /// row is appended and its first cell gets the caret. From the delimiter row: the first body
    /// cell. If the text is already aligned the edit changes nothing: it has an empty range, an
    /// empty replacement and only moves the selection.
    NextCell,
    /// Select the content of the previous cell. `None` in the first cell. From the delimiter
    /// row: the last header cell.
    PreviousCell,
    /// Pad the whole table. `None` if it is aligned already, so it is idempotent. The shell calls
    /// this when the caret has left a table: it passes the caret's old position (which must be
    /// in the table) and can ignore the returned selection, which is that position carried
    /// through the re-alignment.
    Realign,
}

/// A table and, when the queried offset is inside it, the position of that offset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableInfo {
    /// The whole table: from the first cell's line (container prefix excluded) to the end of
    /// its last line.
    pub range: TextRange,
    /// Rows including the header, excluding the delimiter row.
    pub rows: u32,
    pub columns: u32,
    /// 0 is the header. `None` on the delimiter row.
    pub row: Option<u32>,
    /// `None` if the offset is not in a cell (e.g. in the line's container prefix).
    pub column: Option<u32>,
    pub alignments: Vec<ColumnAlignment>,
}

/// A link and where it points (see [`crate::Document::link_at`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkTarget {
    /// The whole link element.
    pub range: TextRange,
    /// As written: angle brackets and title removed, reference labels resolved to the
    /// definition's destination, an email autolink given its `mailto:` scheme. Not decoded
    /// and not made absolute; a bare `www.` URL has no scheme.
    pub destination: String,
}

// ----- Live mode ----------------------------------------------------------------------------

/// What a shell draws in place of (or on top of) concealed source. Decorations are abstract:
/// the shell chooses glyphs, sizes and colors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DecorationKind {
    /// An unordered list marker (`-`, `*`, `+`) drawn as a bullet. The marker stays in the
    /// text; the shell draws over its position. Not emitted for task items (their marker
    /// is hidden instead).
    Bullet,
    /// A task marker `[ ]` / `[x]` drawn as a checkbox the user can click. The item's list
    /// marker, the marker itself and the blanks around them are in `hidden`, whatever the
    /// selection. Only for unordered items: in an ordered item (`1. [ ]`) the number and the
    /// task marker stay visible and no checkbox is drawn.
    Checkbox { checked: bool },
    /// A thematic break drawn as a horizontal rule. Emitted only while its characters are
    /// hidden (the selection is not on its line).
    Rule,
    /// A standalone image drawn in place of its source. `index` is the position in
    /// [`crate::Document::images`]. Emitted only while its source is hidden.
    Image { index: u32 },
    /// The bar beside a block quote; `range` is the whole quote. `depth` is the number of
    /// quotes that enclose this one (0 for an outermost quote).
    QuoteBar { depth: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Decoration {
    /// The source the decoration stands for (the whole quote for `QuoteBar`).
    pub range: TextRange,
    pub kind: DecorationKind,
}

/// What Live mode does to the text for a given selection. The text itself never changes.
///
/// `hidden` is sorted by start and clipped to the queried window; `collapsed` and
/// `decorations` are sorted and include everything that intersects it. The result is a pure
/// function of the current text, the selection and the window: a shell must query again
/// after every edit and every selection change (the dirty range of an edit speaks for spans
/// only, and owners and blocks can change outside it), and for newly visible text when it
/// scrolls.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Concealment {
    /// Ranges not to draw. Sorted, disjoint, merged when adjacent; they never contain a line
    /// terminator and never split a code point.
    pub hidden: Vec<TextRange>,
    /// Whole lines, terminator included, that should take (almost) no vertical space while
    /// concealed: fence and front-matter delimiter lines and setext underlines. Everything
    /// on such a line that is not blank is also in `hidden`.
    pub collapsed: Vec<TextRange>,
    pub decorations: Vec<Decoration>,
}

// ----- focus mode and parts of speech ---------------------------------------------------------

/// How much text focus mode keeps at full strength.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FocusScope {
    /// The sentence (UAX #29) at the caret; a heading or list item holds its own sentences.
    Sentence,
    /// The leaf block at the caret: a paragraph, a heading, one list item's own paragraph, a
    /// whole code block, table or front matter.
    Paragraph,
}

/// The classes of words the editor can colour, for a writing app. A platform tagger maps its
/// own tags onto these; every other word class stays uncoloured.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum PosClass {
    Noun,
    Verb,
    Adjective,
    Adverb,
    Conjunction,
}

/// A word and its class. As input to [`PosUnit::map_tags`] the range is in the unit's joined
/// text (see [`PosUnit`]); as output it is in the document.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PosTag {
    pub range: TextRange,
    pub class: PosClass,
}

/// The prose of one leaf block (or of a stretch of a very long one), which a shell tags as one
/// text.
///
/// The text to tag is the pieces of `prose` joined: a piece directly follows the one before
/// it, except where `separated[i]` is true, which puts one space (one offset unit) between
/// piece `i - 1` and piece `i` (a soft line break, a table cell boundary). Pieces on one line
/// stay joined across inline markup, so a word cut by emphasis (`un**believ**able`) is still
/// one word. Offsets in the joined text count the same units as the document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PosUnit {
    /// The block (or, for prose outside any block, the prose itself; for a stretch of a long
    /// block, from its first piece, or the block's start, to the next stretch).
    pub range: TextRange,
    /// Ranges of the document, sorted and disjoint, free of markup, code, URLs and front matter.
    pub prose: Vec<TextRange>,
    /// Same length as `prose`; `separated[0]` is false.
    pub separated: Vec<bool>,
}

/// Everything a shell wants after the selection moved, in one call (see
/// [`crate::Document::selection_state`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectionState {
    /// `Some` when it was asked for (Live mode).
    pub concealment: Option<Concealment>,
    pub format_state: FormatState,
    /// The table holding the start of the selection.
    pub table: Option<TableInfo>,
    /// `Some` when a scope was given (focus mode on): the ranges kept at full strength, sorted,
    /// disjoint and not touching. Empty: dim everything.
    pub focus: Option<Vec<TextRange>>,
}

/// What a run of highlighted code is, for the colour a shell gives it (the theme's `[syntax]`
/// table). The same eight roles the preview's palette has, plus `Invalid`, which shells colour
/// like `Tag`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CodeRole {
    Comment,
    Keyword,
    String,
    Number,
    Function,
    Type,
    Tag,
    Variable,
    Invalid,
}

/// A run of fenced code with a role. Runs that would be plain are not reported.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CodeHighlight {
    pub range: TextRange,
    pub role: CodeRole,
}

/// The language of a fenced code block, as the highlighter understands it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodeLanguage {
    /// The token as written in the info string (`rust` in "```rust,ignore").
    pub name: String,
    /// The language's own name (`Rust`, `JavaScript`).
    pub display: String,
    /// Where the token is written; replacing it changes the language and keeps the attributes after it.
    pub info_range: TextRange,
    /// The block (its [`Block::range`]).
    pub block: TextRange,
}
