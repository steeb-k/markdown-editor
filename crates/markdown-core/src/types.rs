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
    /// Syntax characters; dimmed in Source mode, concealable in Live mode.
    Markup,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub range: TextRange,
    pub kind: SpanKind,
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
