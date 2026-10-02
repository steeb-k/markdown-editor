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


// ----- Live mode ------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkTarget {
    pub range: Utf16Range,
    pub destination: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DecorationKind {
    Bullet,
    Checkbox { checked: bool },
    Rule,
    Image { index: u32 },
    QuoteBar { depth: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Decoration {
    pub range: Utf16Range,
    pub kind: DecorationKind,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Concealment {
    pub hidden: Vec<Utf16Range>,
    pub collapsed: Vec<Utf16Range>,
    pub decorations: Vec<Decoration>,
}

// ----- editing commands -----------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TextEdit {
    pub range: Utf16Range,
    pub replacement: String,
    pub selection: Utf16Range,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ListKind {
    None,
    Bullet,
    Ordered,
    Task,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ColumnAlignment {
    None,
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FormatCommand {
    Strong,
    Emphasis,
    Strikethrough,
    InlineCode,
    Link,
    Image { destination: String, alt: String },
    LinkTo { destination: String, text: String },
    Heading { level: u8 },
    BlockQuote,
    BulletList,
    OrderedList,
    TaskList,
    CodeBlock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FormatState {
    pub strong: bool,
    pub emphasis: bool,
    pub strikethrough: bool,
    pub inline_code: bool,
    pub link: bool,
    pub heading_level: u8,
    pub in_quote: bool,
    pub list: ListKind,
    pub in_code_block: bool,
    pub in_table: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TableCommand {
    Insert { rows: u32, columns: u32 },
    AddRowAbove,
    AddRowBelow,
    AddColumnLeft,
    AddColumnRight,
    DeleteRow,
    DeleteColumn,
    SetAlignment { alignment: ColumnAlignment },
    NextCell,
    PreviousCell,
    Realign,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableInfo {
    pub range: Utf16Range,
    pub rows: u32,
    pub columns: u32,
    pub row: Option<u32>,
    pub column: Option<u32>,
    pub alignments: Vec<ColumnAlignment>,
}

// ----- themes ---------------------------------------------------------------------------------------

/// An sRGB color. Named `ThemeColor` here (the core calls it `Color`) because Swift would
/// otherwise find it ambiguous with SwiftUI's `Color`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ThemeColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ThemeColors {
    pub background: ThemeColor,
    pub text: ThemeColor,
    pub markup: ThemeColor,
    pub heading: ThemeColor,
    pub link: ThemeColor,
    pub code_text: ThemeColor,
    pub code_background: ThemeColor,
    pub quote: ThemeColor,
    pub selection: ThemeColor,
    pub caret: ThemeColor,
    pub focus_dim: ThemeColor,
    pub pos_noun: ThemeColor,
    pub pos_verb: ThemeColor,
    pub pos_adjective: ThemeColor,
    pub pos_adverb: ThemeColor,
    pub pos_conjunction: ThemeColor,
    pub author_ai: ThemeColor,
    pub author_reference: ThemeColor,
    pub rule: ThemeColor,
    pub table_border: ThemeColor,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub is_dark: bool,
    pub colors: ThemeColors,
}

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

impl From<core::DecorationKind> for DecorationKind {
    fn from(k: core::DecorationKind) -> Self {
        match k {
            core::DecorationKind::Bullet => Self::Bullet,
            core::DecorationKind::Checkbox { checked } => Self::Checkbox { checked },
            core::DecorationKind::Rule => Self::Rule,
            core::DecorationKind::Image { index } => Self::Image { index },
            core::DecorationKind::QuoteBar { depth } => Self::QuoteBar { depth },
        }
    }
}

impl From<core::Concealment> for Concealment {
    fn from(c: core::Concealment) -> Self {
        Self {
            hidden: c.hidden.into_iter().map(Into::into).collect(),
            collapsed: c.collapsed.into_iter().map(Into::into).collect(),
            decorations: c
                .decorations
                .into_iter()
                .map(|d| Decoration { range: d.range.into(), kind: d.kind.into() })
                .collect(),
        }
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

impl From<core::TextEdit> for TextEdit {
    fn from(e: core::TextEdit) -> Self {
        TextEdit { range: e.range.into(), replacement: e.replacement, selection: e.selection.into() }
    }
}

impl From<core::ListKind> for ListKind {
    fn from(k: core::ListKind) -> Self {
        match k {
            core::ListKind::None => ListKind::None,
            core::ListKind::Bullet => ListKind::Bullet,
            core::ListKind::Ordered => ListKind::Ordered,
            core::ListKind::Task => ListKind::Task,
        }
    }
}

impl From<core::ColumnAlignment> for ColumnAlignment {
    fn from(a: core::ColumnAlignment) -> Self {
        match a {
            core::ColumnAlignment::None => ColumnAlignment::None,
            core::ColumnAlignment::Left => ColumnAlignment::Left,
            core::ColumnAlignment::Center => ColumnAlignment::Center,
            core::ColumnAlignment::Right => ColumnAlignment::Right,
        }
    }
}

impl From<ColumnAlignment> for core::ColumnAlignment {
    fn from(a: ColumnAlignment) -> Self {
        match a {
            ColumnAlignment::None => core::ColumnAlignment::None,
            ColumnAlignment::Left => core::ColumnAlignment::Left,
            ColumnAlignment::Center => core::ColumnAlignment::Center,
            ColumnAlignment::Right => core::ColumnAlignment::Right,
        }
    }
}

impl From<FormatCommand> for core::FormatCommand {
    fn from(c: FormatCommand) -> Self {
        match c {
            FormatCommand::Strong => core::FormatCommand::Strong,
            FormatCommand::Emphasis => core::FormatCommand::Emphasis,
            FormatCommand::Strikethrough => core::FormatCommand::Strikethrough,
            FormatCommand::InlineCode => core::FormatCommand::InlineCode,
            FormatCommand::Link => core::FormatCommand::Link,
            FormatCommand::Image { destination, alt } => core::FormatCommand::Image { destination, alt },
            FormatCommand::LinkTo { destination, text } => core::FormatCommand::LinkTo { destination, text },
            FormatCommand::Heading { level } => core::FormatCommand::Heading { level },
            FormatCommand::BlockQuote => core::FormatCommand::BlockQuote,
            FormatCommand::BulletList => core::FormatCommand::BulletList,
            FormatCommand::OrderedList => core::FormatCommand::OrderedList,
            FormatCommand::TaskList => core::FormatCommand::TaskList,
            FormatCommand::CodeBlock => core::FormatCommand::CodeBlock,
        }
    }
}

impl From<core::FormatState> for FormatState {
    fn from(s: core::FormatState) -> Self {
        FormatState {
            strong: s.strong,
            emphasis: s.emphasis,
            strikethrough: s.strikethrough,
            inline_code: s.inline_code,
            link: s.link,
            heading_level: s.heading_level,
            in_quote: s.in_quote,
            list: s.list.into(),
            in_code_block: s.in_code_block,
            in_table: s.in_table,
        }
    }
}

impl From<TableCommand> for core::TableCommand {
    fn from(c: TableCommand) -> Self {
        match c {
            TableCommand::Insert { rows, columns } => core::TableCommand::Insert { rows, columns },
            TableCommand::AddRowAbove => core::TableCommand::AddRowAbove,
            TableCommand::AddRowBelow => core::TableCommand::AddRowBelow,
            TableCommand::AddColumnLeft => core::TableCommand::AddColumnLeft,
            TableCommand::AddColumnRight => core::TableCommand::AddColumnRight,
            TableCommand::DeleteRow => core::TableCommand::DeleteRow,
            TableCommand::DeleteColumn => core::TableCommand::DeleteColumn,
            TableCommand::SetAlignment { alignment } => core::TableCommand::SetAlignment(alignment.into()),
            TableCommand::NextCell => core::TableCommand::NextCell,
            TableCommand::PreviousCell => core::TableCommand::PreviousCell,
            TableCommand::Realign => core::TableCommand::Realign,
        }
    }
}

impl From<core::TableInfo> for TableInfo {
    fn from(t: core::TableInfo) -> Self {
        TableInfo {
            range: t.range.into(),
            rows: t.rows,
            columns: t.columns,
            row: t.row,
            column: t.column,
            alignments: t.alignments.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<core::Color> for ThemeColor {
    fn from(c: core::Color) -> Self {
        ThemeColor { r: c.r, g: c.g, b: c.b, a: c.a }
    }
}

impl From<core::theme::Colors> for ThemeColors {
    fn from(c: core::theme::Colors) -> Self {
        ThemeColors {
            background: c.background.into(),
            text: c.text.into(),
            markup: c.markup.into(),
            heading: c.heading.into(),
            link: c.link.into(),
            code_text: c.code_text.into(),
            code_background: c.code_background.into(),
            quote: c.quote.into(),
            selection: c.selection.into(),
            caret: c.caret.into(),
            focus_dim: c.focus_dim.into(),
            pos_noun: c.pos_noun.into(),
            pos_verb: c.pos_verb.into(),
            pos_adjective: c.pos_adjective.into(),
            pos_adverb: c.pos_adverb.into(),
            pos_conjunction: c.pos_conjunction.into(),
            author_ai: c.author_ai.into(),
            author_reference: c.author_reference.into(),
            rule: c.rule.into(),
            table_border: c.table_border.into(),
        }
    }
}

impl From<core::Theme> for Theme {
    fn from(t: core::Theme) -> Self {
        Theme { id: t.id, name: t.name, is_dark: t.is_dark, colors: t.colors.into() }
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

    pub fn link_at(&self, offset: u32) -> Option<LinkTarget> {
        self.with(|d| d.link_at(offset).map(|l| LinkTarget { range: l.range.into(), destination: l.destination }))
    }

    pub fn concealment(&self, selection: Utf16Range, within: Option<Utf16Range>) -> Concealment {
        self.with(|d| d.concealment(selection.into(), within.map(Into::into)).into())
    }

    pub fn format(&self, command: FormatCommand, selection: Utf16Range) -> Option<TextEdit> {
        self.with(|d| d.format(command.into(), selection.into()).map(TextEdit::from))
    }

    pub fn format_state(&self, selection: Utf16Range) -> FormatState {
        self.with(|d| d.format_state(selection.into()).into())
    }

    pub fn newline(&self, selection: Utf16Range) -> Option<TextEdit> {
        self.with(|d| d.newline(selection.into()).map(TextEdit::from))
    }

    pub fn indent(&self, selection: Utf16Range, outdent: bool) -> Option<TextEdit> {
        self.with(|d| d.indent(selection.into(), outdent).map(TextEdit::from))
    }

    pub fn toggle_task(&self, at: u32) -> Option<TextEdit> {
        self.with(|d| d.toggle_task(at).map(TextEdit::from))
    }

    pub fn table_command(&self, command: TableCommand, selection: Utf16Range) -> Option<TextEdit> {
        self.with(|d| d.table_command(command.into(), selection.into()).map(TextEdit::from))
    }

    pub fn table_at(&self, offset: u32) -> Option<TableInfo> {
        self.with(|d| d.table_at(offset).map(TableInfo::from))
    }
}

#[uniffi::export]
pub fn builtin_themes() -> Vec<Theme> {
    core::builtin_themes().into_iter().map(Theme::from).collect()
}

#[uniffi::export]
pub fn theme_by_id(id: String) -> Option<Theme> {
    core::theme_by_id(&id).map(Theme::from)
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
    fn commands_and_themes_cross_the_boundary() {
        let d = Document::new("\u{1F389} word".into());
        // Selection in UTF-16 units: the emoji is two of them.
        let edit = d
            .format(FormatCommand::Strong, Utf16Range { start: 3, end: 7 })
            .expect("wraps the word");
        assert_eq!(edit.replacement, "**word**");
        assert_eq!(edit.selection, Utf16Range { start: 5, end: 9 });
        d.replace(edit.range, edit.replacement.clone()).unwrap();
        assert_eq!(d.text(), "\u{1F389} **word**");
        assert!(d.format_state(Utf16Range { start: 6, end: 6 }).strong);
        let t = Document::new("| a |\n|---|\n| b |".into());
        assert_eq!(t.table_at(2).map(|i| (i.rows, i.columns)), Some((2, 1)));
        assert!(t.table_command(TableCommand::SetAlignment { alignment: ColumnAlignment::Right }, Utf16Range { start: 2, end: 2 }).is_some());
        assert_eq!(builtin_themes().len(), 3);
        assert!(theme_by_id("sepia".into()).is_some());
    }

    #[test]
    fn concealment_crosses_the_boundary() {
        let d = Document::new("\u{1F389} **bold**\n\n- [x] t\n".into());
        let far = Utf16Range { start: 0, end: 0 };
        let c = d.concealment(far, None);
        // Emoji is two UTF-16 units; the hidden ranges are in those units.
        assert_eq!(c.hidden[..2], [Utf16Range { start: 3, end: 5 }, Utf16Range { start: 9, end: 11 }]);
        assert!(c.decorations.iter().any(|d| d.kind == DecorationKind::Checkbox { checked: true }));
        let inside = d.concealment(Utf16Range { start: 6, end: 6 }, Some(Utf16Range { start: 0, end: 12 }));
        assert!(inside.hidden.is_empty());
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
