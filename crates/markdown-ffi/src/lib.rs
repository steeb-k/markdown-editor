//! UniFFI surface over `markdown-core`. Contains no logic: it mirrors the core's records and
//! enums, fixes the offset encoding to UTF-16 and wraps `Document` in a `Mutex`.

use std::sync::Mutex;

use markdown_core as core;

uniffi::setup_scaffolding!();

// ----- records and enums ------------------------------------------------------------------

/// Half-open range in UTF-16 code units. Named `Utf16Range` here (the core calls it
/// `TextRange`) because Swift would otherwise find it ambiguous with the C struct
/// `TextRange` from CoreServices, which AppKit and Foundation pull in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Utf16Range {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SpanKind {
    Heading { level: u8 },
    Emphasis,
    Strong,
    Strikethrough,
    InlineCode,
    CodeBlock,
    CodeInfo,
    Link,
    LinkDestination,
    Image,
    BlockQuote,
    ListMarker { ordered: bool },
    TaskMarker { checked: bool },
    Table,
    TableDelimiterRow,
    FootnoteReference,
    FootnoteDefinition,
    FrontMatter,
    ThematicBreak,
    Html,
    HardBreak,
    Markup,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Span {
    pub range: Utf16Range,
    pub kind: SpanKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BlockKind {
    Paragraph,
    Heading,
    CodeBlock,
    Table,
    HtmlBlock,
    ThematicBreak,
    FrontMatter,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Block {
    pub kind: BlockKind,
    pub range: Utf16Range,
    pub line: u32,
    pub heading_level: Option<u8>,
    pub depth: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImageRef {
    pub range: Utf16Range,
    pub destination: String,
    pub alt: String,
    pub title: Option<String>,
    pub standalone: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MarkupScope {
    Inline,
    Line,
    Block,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MarkupSpan {
    pub range: Utf16Range,
    pub owner: Utf16Range,
    pub scope: MarkupScope,
    pub in_table: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Update {
    pub dirty: Utf16Range,
    pub revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum EditError {
    OutOfBounds,
    InvertedRange,
    NotOnCodePointBoundary,
    TooLarge,
}

impl std::fmt::Display for EditError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        core::EditError::from(*self).fmt(f)
    }
}

impl std::error::Error for EditError {}

// ----- conversions (field-by-field, no logic) -----------------------------------------------

impl From<Utf16Range> for core::TextRange {
    fn from(r: Utf16Range) -> Self {
        core::TextRange::new(r.start, r.end)
    }
}
impl From<core::TextRange> for Utf16Range {
    fn from(r: core::TextRange) -> Self {
        Utf16Range { start: r.start, end: r.end }
    }
}

impl From<core::SpanKind> for SpanKind {
    fn from(k: core::SpanKind) -> Self {
        use core::SpanKind as K;
        match k {
            K::Heading { level } => SpanKind::Heading { level },
            K::Emphasis => SpanKind::Emphasis,
            K::Strong => SpanKind::Strong,
            K::Strikethrough => SpanKind::Strikethrough,
            K::InlineCode => SpanKind::InlineCode,
            K::CodeBlock => SpanKind::CodeBlock,
            K::CodeInfo => SpanKind::CodeInfo,
            K::Link => SpanKind::Link,
            K::LinkDestination => SpanKind::LinkDestination,
            K::Image => SpanKind::Image,
            K::BlockQuote => SpanKind::BlockQuote,
            K::ListMarker { ordered } => SpanKind::ListMarker { ordered },
            K::TaskMarker { checked } => SpanKind::TaskMarker { checked },
            K::Table => SpanKind::Table,
            K::TableDelimiterRow => SpanKind::TableDelimiterRow,
            K::FootnoteReference => SpanKind::FootnoteReference,
            K::FootnoteDefinition => SpanKind::FootnoteDefinition,
            K::FrontMatter => SpanKind::FrontMatter,
            K::ThematicBreak => SpanKind::ThematicBreak,
            K::Html => SpanKind::Html,
            K::HardBreak => SpanKind::HardBreak,
            K::Markup => SpanKind::Markup,
        }
    }
}

impl From<core::Span> for Span {
    fn from(s: core::Span) -> Self {
        Span { range: s.range.into(), kind: s.kind.into() }
    }
}

impl From<core::BlockKind> for BlockKind {
    fn from(k: core::BlockKind) -> Self {
        use core::BlockKind as K;
        match k {
            K::Paragraph => BlockKind::Paragraph,
            K::Heading => BlockKind::Heading,
            K::CodeBlock => BlockKind::CodeBlock,
            K::Table => BlockKind::Table,
            K::HtmlBlock => BlockKind::HtmlBlock,
            K::ThematicBreak => BlockKind::ThematicBreak,
            K::FrontMatter => BlockKind::FrontMatter,
        }
    }
}

impl From<core::Block> for Block {
    fn from(b: core::Block) -> Self {
        Block {
            kind: b.kind.into(),
            range: b.range.into(),
            line: b.line,
            heading_level: b.heading_level,
            depth: b.depth,
        }
    }
}

impl From<core::ImageRef> for ImageRef {
    fn from(i: core::ImageRef) -> Self {
        ImageRef {
            range: i.range.into(),
            destination: i.destination,
            alt: i.alt,
            title: i.title,
            standalone: i.standalone,
        }
    }
}

impl From<core::MarkupScope> for MarkupScope {
    fn from(s: core::MarkupScope) -> Self {
        match s {
            core::MarkupScope::Inline => MarkupScope::Inline,
            core::MarkupScope::Line => MarkupScope::Line,
            core::MarkupScope::Block => MarkupScope::Block,
        }
    }
}

impl From<core::MarkupSpan> for MarkupSpan {
    fn from(m: core::MarkupSpan) -> Self {
        MarkupSpan {
            range: m.range.into(),
            owner: m.owner.into(),
            scope: m.scope.into(),
            in_table: m.in_table,
        }
    }
}

impl From<core::Update> for Update {
    fn from(u: core::Update) -> Self {
        Update { dirty: u.dirty.into(), revision: u.revision }
    }
}

impl From<core::EditError> for EditError {
    fn from(e: core::EditError) -> Self {
        match e {
            core::EditError::OutOfBounds => EditError::OutOfBounds,
            core::EditError::InvertedRange => EditError::InvertedRange,
            core::EditError::NotOnCodePointBoundary => EditError::NotOnCodePointBoundary,
            core::EditError::TooLarge => EditError::TooLarge,
        }
    }
}

impl From<EditError> for core::EditError {
    fn from(e: EditError) -> Self {
        match e {
            EditError::OutOfBounds => core::EditError::OutOfBounds,
            EditError::InvertedRange => core::EditError::InvertedRange,
            EditError::NotOnCodePointBoundary => core::EditError::NotOnCodePointBoundary,
            EditError::TooLarge => core::EditError::TooLarge,
        }
    }
}

// ----- the document object ------------------------------------------------------------------

/// A Markdown document. Every range crossing this API is in UTF-16 code units.
#[derive(uniffi::Object)]
pub struct Document {
    inner: Mutex<core::Document>,
}

impl Document {
    fn with<R>(&self, f: impl FnOnce(&mut core::Document) -> R) -> R {
        // A poisoned lock only means a previous call panicked; the document is still usable.
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard)
    }
}

#[uniffi::export]
impl Document {
    #[uniffi::constructor]
    pub fn new(text: String) -> Self {
        Self { inner: Mutex::new(core::Document::new(&text, core::OffsetEncoding::Utf16)) }
    }

    pub fn text(&self) -> String {
        self.with(|d| d.text().to_owned())
    }

    /// Length in UTF-16 code units.
    pub fn len(&self) -> u32 {
        self.with(|d| d.len())
    }

    pub fn is_empty(&self) -> bool {
        self.with(|d| d.is_empty())
    }

    pub fn revision(&self) -> u64 {
        self.with(|d| d.revision())
    }

    pub fn replace(&self, range: Utf16Range, with: String) -> Result<Update, EditError> {
        self.with(|d| d.replace(range.into(), &with).map(Update::from).map_err(EditError::from))
    }

    pub fn set_text(&self, text: String) -> Update {
        self.with(|d| d.set_text(&text).into())
    }

    pub fn spans(&self, within: Option<Utf16Range>) -> Vec<Span> {
        self.with(|d| d.spans(within.map(Into::into)).into_iter().map(Span::from).collect())
    }

    pub fn markup_spans(&self, within: Option<Utf16Range>) -> Vec<MarkupSpan> {
        self.with(|d| d.markup_spans(within.map(Into::into)).into_iter().map(MarkupSpan::from).collect())
    }

    pub fn blocks(&self) -> Vec<Block> {
        self.with(|d| d.blocks().into_iter().map(Block::from).collect())
    }

    pub fn prose_ranges(&self, within: Option<Utf16Range>) -> Vec<Utf16Range> {
        self.with(|d| d.prose_ranges(within.map(Into::into)).into_iter().map(Utf16Range::from).collect())
    }

    pub fn images(&self) -> Vec<ImageRef> {
        self.with(|d| d.images().into_iter().map(ImageRef::from).collect())
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    core::core_version().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let d = Document::new("h\u{e9}llo \u{1F389}".into());
        assert_eq!(d.text(), "h\u{e9}llo \u{1F389}");
        assert_eq!(d.len(), 8);
        assert!(!core_version().is_empty());
    }

    #[test]
    fn replace_error_maps() {
        let d = Document::new("\u{1F389}".into());
        assert_eq!(d.replace(Utf16Range { start: 1, end: 1 }, "x".into()), Err(EditError::NotOnCodePointBoundary));
        let u = d.replace(Utf16Range { start: 2, end: 2 }, "*a*".into()).unwrap();
        assert_eq!(u.revision, 1);
        assert_eq!(d.spans(None).len(), 3);
    }
}
