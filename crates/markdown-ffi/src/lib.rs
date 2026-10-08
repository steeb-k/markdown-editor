//! UniFFI surface over `markdown-core`. Contains no logic: it mirrors the core's records and
//! enums, fixes the offset encoding to UTF-16 and wraps `Document` in a `Mutex`.

use std::sync::Mutex;

use markdown_core as core;

uniffi::setup_scaffolding!();

mod authorship;
pub use authorship::*;
mod history;
mod library;
mod template;
pub use history::*;
pub use library::*;
pub use template::*;

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
    Wikilink,
    Tag,
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
pub struct OutlineEntry {
    pub level: u8,
    pub text: String,
    pub range: Utf16Range,
    pub line: u32,
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


// ----- code highlighting -----------------------------------------------------------------------------

/// What a run of highlighted code is (see `core::CodeRole`); the shell colours it from the theme's
/// `[syntax]` palette (`Invalid` like `Tag`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CodeHighlight {
    pub range: Utf16Range,
    pub role: CodeRole,
}

/// The language of a fenced block (see `core::CodeLanguage`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CodeLanguage {
    pub name: String,
    pub display: String,
    pub info_range: Utf16Range,
    pub block: Utf16Range,
}

/// One entry of the language menu: the token to write and the name to show, and whether it is one
/// of the common languages the list starts with.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CodeLanguageChoice {
    pub token: String,
    pub display: String,
    pub common: bool,
}

impl From<core::CodeRole> for CodeRole {
    fn from(r: core::CodeRole) -> Self {
        use core::CodeRole as R;
        match r {
            R::Comment => CodeRole::Comment,
            R::Keyword => CodeRole::Keyword,
            R::String => CodeRole::String,
            R::Number => CodeRole::Number,
            R::Function => CodeRole::Function,
            R::Type => CodeRole::Type,
            R::Tag => CodeRole::Tag,
            R::Variable => CodeRole::Variable,
            R::Invalid => CodeRole::Invalid,
        }
    }
}

impl From<core::CodeHighlight> for CodeHighlight {
    fn from(h: core::CodeHighlight) -> Self {
        CodeHighlight { range: h.range.into(), role: h.role.into() }
    }
}

impl From<core::CodeLanguage> for CodeLanguage {
    fn from(l: core::CodeLanguage) -> Self {
        CodeLanguage { name: l.name, display: l.display, info_range: l.info_range.into(), block: l.block.into() }
    }
}

// ----- Live mode ------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkTarget {
    pub range: Utf16Range,
    pub destination: String,
}

/// A wikilink and where it points (see `core::WikilinkRef`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WikilinkRef {
    pub range: Utf16Range,
    pub target: String,
    pub heading: Option<String>,
    pub label: Option<String>,
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

// ----- focus mode and parts of speech ---------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FocusScope {
    Sentence,
    Paragraph,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PosClass {
    Noun,
    Verb,
    Adjective,
    Adverb,
    Conjunction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PosTag {
    pub range: Utf16Range,
    pub class: PosClass,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PosUnit {
    pub range: Utf16Range,
    pub prose: Vec<Utf16Range>,
    pub separated: Vec<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SelectionState {
    pub concealment: Option<Concealment>,
    pub format_state: FormatState,
    pub table: Option<TableInfo>,
    pub focus: Option<Vec<Utf16Range>>,
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
    pub syntax: ThemeSyntax,
}

/// The colours of the code highlighter's roles (the theme's `[syntax]` table).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ThemeSyntax {
    pub comment: ThemeColor,
    pub keyword: ThemeColor,
    pub string: ThemeColor,
    pub number: ThemeColor,
    pub function: ThemeColor,
    pub type_: ThemeColor,
    pub tag: ThemeColor,
    pub variable: ThemeColor,
}

// ----- preview and export ----------------------------------------------------------------------

/// How the preview's text is set: the editor's own settings in CSS terms. See `core::Typography`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Typography {
    pub font_family: String,
    pub mono_family: String,
    pub font_size_px: f64,
    pub line_height: f64,
    pub measure_ch: f64,
}

/// A theme and typography for a standalone document's stylesheet.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PreviewStyle {
    pub theme: Theme,
    pub typography: Typography,
}

/// What `Document::render_html` renders and how. See `core::RenderOptions`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RenderOptions {
    #[uniffi(default = false)]
    pub source_lines: bool,
    #[uniffi(default = false)]
    pub standalone: bool,
    #[uniffi(default = false)]
    pub sanitize: bool,
    #[uniffi(default = true)]
    pub highlight: bool,
    #[uniffi(default = "")]
    pub fallback_title: String,
    #[uniffi(default = None)]
    pub style: Option<PreviewStyle>,
    #[uniffi(default = [])]
    pub image_sizes: Vec<ImageSize>,
}

/// A picture's size in points for the destination as written (see `core::ImageSize`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImageSize {
    pub destination: String,
    pub width: u32,
    pub height: u32,
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
            K::Wikilink => SpanKind::Wikilink,
            K::Tag => SpanKind::Tag,
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

impl From<core::OutlineEntry> for OutlineEntry {
    fn from(e: core::OutlineEntry) -> Self {
        OutlineEntry { level: e.level, text: e.text, range: e.range.into(), line: e.line }
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

impl From<FocusScope> for core::FocusScope {
    fn from(s: FocusScope) -> Self {
        match s {
            FocusScope::Sentence => core::FocusScope::Sentence,
            FocusScope::Paragraph => core::FocusScope::Paragraph,
        }
    }
}

impl From<PosClass> for core::PosClass {
    fn from(c: PosClass) -> Self {
        match c {
            PosClass::Noun => core::PosClass::Noun,
            PosClass::Verb => core::PosClass::Verb,
            PosClass::Adjective => core::PosClass::Adjective,
            PosClass::Adverb => core::PosClass::Adverb,
            PosClass::Conjunction => core::PosClass::Conjunction,
        }
    }
}

impl From<core::PosClass> for PosClass {
    fn from(c: core::PosClass) -> Self {
        match c {
            core::PosClass::Noun => PosClass::Noun,
            core::PosClass::Verb => PosClass::Verb,
            core::PosClass::Adjective => PosClass::Adjective,
            core::PosClass::Adverb => PosClass::Adverb,
            core::PosClass::Conjunction => PosClass::Conjunction,
        }
    }
}

impl From<PosTag> for core::PosTag {
    fn from(t: PosTag) -> Self {
        core::PosTag { range: t.range.into(), class: t.class.into() }
    }
}

impl From<core::PosTag> for PosTag {
    fn from(t: core::PosTag) -> Self {
        PosTag { range: t.range.into(), class: t.class.into() }
    }
}

impl From<core::PosUnit> for PosUnit {
    fn from(u: core::PosUnit) -> Self {
        PosUnit { range: u.range.into(), prose: u.prose.into_iter().map(Into::into).collect(), separated: u.separated }
    }
}

impl From<PosUnit> for core::PosUnit {
    fn from(u: PosUnit) -> Self {
        core::PosUnit { range: u.range.into(), prose: u.prose.into_iter().map(Into::into).collect(), separated: u.separated }
    }
}

impl From<core::SelectionState> for SelectionState {
    fn from(s: core::SelectionState) -> Self {
        SelectionState {
            concealment: s.concealment.map(Into::into),
            format_state: s.format_state.into(),
            table: s.table.map(Into::into),
            focus: s.focus.map(|f| f.into_iter().map(Into::into).collect()),
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

impl From<ThemeColor> for core::Color {
    fn from(c: ThemeColor) -> Self {
        core::Color { r: c.r, g: c.g, b: c.b, a: c.a }
    }
}

impl From<ThemeColors> for core::theme::Colors {
    fn from(c: ThemeColors) -> Self {
        core::theme::Colors {
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

impl From<Theme> for core::Theme {
    fn from(t: Theme) -> Self {
        core::Theme { id: t.id, name: t.name, is_dark: t.is_dark, colors: t.colors.into(), syntax: t.syntax.into() }
    }
}

impl From<Typography> for core::Typography {
    fn from(t: Typography) -> Self {
        core::Typography {
            font_family: t.font_family,
            mono_family: t.mono_family,
            font_size_px: t.font_size_px,
            line_height: t.line_height,
            measure_ch: t.measure_ch,
        }
    }
}

impl From<PreviewStyle> for core::PreviewStyle {
    fn from(s: PreviewStyle) -> Self {
        core::PreviewStyle { theme: s.theme.into(), typography: s.typography.into() }
    }
}

impl From<RenderOptions> for core::RenderOptions {
    fn from(o: RenderOptions) -> Self {
        core::RenderOptions {
            source_lines: o.source_lines,
            standalone: o.standalone,
            sanitize: o.sanitize,
            highlight: o.highlight,
            fallback_title: o.fallback_title,
            style: o.style.map(Into::into),
            image_sizes: o.image_sizes.into_iter().map(|s| core::ImageSize { destination: s.destination, width: s.width, height: s.height }).collect(),
        }
    }
}

impl From<core::Theme> for Theme {
    fn from(t: core::Theme) -> Self {
        Theme { id: t.id, name: t.name, is_dark: t.is_dark, colors: t.colors.into(), syntax: t.syntax.into() }
    }
}

impl From<ThemeSyntax> for core::SyntaxPalette {
    fn from(p: ThemeSyntax) -> Self {
        core::SyntaxPalette {
            comment: p.comment.into(),
            keyword: p.keyword.into(),
            string: p.string.into(),
            number: p.number.into(),
            function: p.function.into(),
            type_: p.type_.into(),
            tag: p.tag.into(),
            variable: p.variable.into(),
        }
    }
}

impl From<core::SyntaxPalette> for ThemeSyntax {
    fn from(p: core::SyntaxPalette) -> Self {
        ThemeSyntax {
            comment: p.comment.into(),
            keyword: p.keyword.into(),
            string: p.string.into(),
            number: p.number.into(),
            function: p.function.into(),
            type_: p.type_.into(),
            tag: p.tag.into(),
            variable: p.variable.into(),
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

    /// The headings in order, for an outline.
    pub fn outline(&self) -> Vec<OutlineEntry> {
        self.with(|d| d.outline().into_iter().map(OutlineEntry::from).collect())
    }

    pub fn images(&self) -> Vec<ImageRef> {
        self.with(|d| d.images().into_iter().map(ImageRef::from).collect())
    }

    pub fn link_at(&self, offset: u32) -> Option<LinkTarget> {
        self.with(|d| d.link_at(offset).map(|l| LinkTarget { range: l.range.into(), destination: l.destination }))
    }

    pub fn wikilink_at(&self, offset: u32) -> Option<WikilinkRef> {
        self.with(|d| {
            d.wikilink_at(offset)
                .map(|w| WikilinkRef { range: w.range.into(), target: w.target, heading: w.heading, label: w.label })
        })
    }

    /// Colour roles of the fenced code meeting `within`, clipped to it (see `core::Document::code_highlights`).
    pub fn code_highlights(&self, within: Option<Utf16Range>) -> Vec<CodeHighlight> {
        self.with(|d| d.code_highlights(within.map(Into::into)).into_iter().map(CodeHighlight::from).collect())
    }

    /// `range` widened to whole fenced blocks.
    pub fn code_extent(&self, range: Utf16Range) -> Utf16Range {
        self.with(|d| d.code_extent(range.into()).into())
    }

    pub fn code_language_at(&self, offset: u32) -> Option<CodeLanguage> {
        self.with(|d| d.code_language_at(offset).map(CodeLanguage::from))
    }

    /// The known languages of the fenced blocks meeting `within`.
    pub fn code_languages(&self, within: Option<Utf16Range>) -> Vec<CodeLanguage> {
        self.with(|d| d.code_languages(within.map(Into::into)).into_iter().map(CodeLanguage::from).collect())
    }

    /// The `template:` named in the front matter block at the start of the text, if any.
    pub fn front_matter_template(&self) -> Option<String> {
        self.with(|d| d.front_matter_template())
    }

    /// The edit that makes `name` the front matter's `template:` (adding the line, or a block, as needed), or removes the
    /// key and a block it leaves empty when `name` is `None` or blank. `None` when nothing would change.
    pub fn set_front_matter_template(&self, name: Option<String>) -> Option<TextEdit> {
        self.with(|d| d.set_front_matter_template(name.as_deref()).map(TextEdit::from))
    }

    /// The document's own measure: the front matter's `line_width:` when it is an integer from 30 to 160.
    pub fn front_matter_line_width(&self) -> Option<u32> {
        self.with(|d| d.front_matter_line_width())
    }

    /// The edit that makes `width` the front matter's `line_width:`, or removes the key (and a block it leaves empty)
    /// for `None`. `None` when nothing would change.
    pub fn set_front_matter_line_width(&self, width: Option<u32>) -> Option<TextEdit> {
        self.with(|d| d.set_front_matter_line_width(width).map(TextEdit::from))
    }

    /// The edit that makes the fenced block `block` `token`'s language, keeping its other attributes.
    pub fn set_code_language(&self, block: Utf16Range, token: String) -> Option<TextEdit> {
        self.with(|d| d.set_code_language(block.into(), &token).map(TextEdit::from))
    }

    pub fn concealment(&self, selection: Utf16Range, within: Option<Utf16Range>) -> Concealment {
        self.with(|d| d.concealment(selection.into(), within.map(Into::into)).into())
    }

    pub fn focus_range(&self, selection: Utf16Range, scope: FocusScope) -> Vec<Utf16Range> {
        self.with(|d| d.focus_range(selection.into(), scope.into()).into_iter().map(Utf16Range::from).collect())
    }

    pub fn pos_units(&self, within: Option<Utf16Range>) -> Vec<PosUnit> {
        self.with(|d| d.pos_units(within.map(Into::into)).into_iter().map(PosUnit::from).collect())
    }

    pub fn selection_state(
        &self,
        selection: Utf16Range,
        within: Option<Utf16Range>,
        conceal: bool,
        focus: Option<FocusScope>,
    ) -> SelectionState {
        self.with(|d| d.selection_state(selection.into(), within.map(Into::into), conceal, focus.map(Into::into)).into())
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

    /// The document as HTML: the body, or a complete page with `options.standalone`.
    pub fn render_html(&self, options: RenderOptions) -> String {
        self.with(|d| d.render_html(&options.into()))
    }

    /// The whole blocks `range` touches as HTML; an empty range is the whole document.
    pub fn render_html_fragment(&self, range: Utf16Range, options: RenderOptions) -> String {
        self.with(|d| d.render_html_fragment(range.into(), &options.into()))
    }
}

/// Words of a unit's joined text (ranges in its coordinates) as document ranges.
#[uniffi::export]
pub fn pos_map_tags(unit: PosUnit, words: Vec<PosTag>) -> Vec<PosTag> {
    let words: Vec<core::PosTag> = words.into_iter().map(Into::into).collect();
    core::PosUnit::from(unit).map_tags(&words).into_iter().map(PosTag::from).collect()
}

/// Length of a unit's joined text in UTF-16 units.
#[uniffi::export]
pub fn pos_joined_len(unit: PosUnit) -> u32 {
    core::PosUnit::from(unit).joined_len()
}

#[uniffi::export]
pub fn builtin_themes() -> Vec<Theme> {
    core::builtin_themes().into_iter().map(Theme::from).collect()
}

#[uniffi::export]
pub fn theme_by_id(id: String) -> Option<Theme> {
    core::theme_by_id(&id).map(Theme::from)
}

/// The preview's stylesheet for a theme set in the given typography (with its print section).
#[uniffi::export]
pub fn preview_css(theme: Theme, typography: Typography) -> String {
    core::preview_css(&theme.into(), &typography.into())
}

/// The languages a code block can be given, common ones first, then the rest alphabetically.
#[uniffi::export]
pub fn code_language_choices() -> Vec<CodeLanguageChoice> {
    let common = core::common_language_count();
    core::languages()
        .iter()
        .enumerate()
        .map(|(i, (t, d))| CodeLanguageChoice { token: t.clone(), display: d.clone(), common: i < common })
        .collect()
}

/// Loads the code highlighter's syntaxes now. Call once from a background thread before the first
/// preview is shown (the work is done lazily otherwise, on the first fenced block).
#[uniffi::export]
pub fn warm_up_highlighting() {
    core::highlight::warm_up();
}

/// The id the renderer gives a heading with this text (before de-duplication).
#[uniffi::export]
pub fn heading_slug(text: String) -> String {
    core::slug(&text)
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
    fn code_highlighting_crosses_the_boundary() {
        let d = Document::new("\u{1F389}\n\n```rust\nlet s = \"\u{1F389}\"; // c\n```\n".into());
        let hs = d.code_highlights(None);
        assert!(hs.iter().any(|h| h.role == CodeRole::Keyword && h.range == Utf16Range { start: 12, end: 15 }), "{hs:?}");
        assert!(hs.iter().any(|h| h.role == CodeRole::String));
        let l = d.code_language_at(5).unwrap();
        assert_eq!((l.name.as_str(), l.display.as_str()), ("rust", "Rust"));
        assert_eq!(d.code_languages(None), vec![l.clone()]);
        let edit = d.set_code_language(l.block, "python".into()).unwrap();
        d.replace(edit.range, edit.replacement).unwrap();
        assert!(d.text().contains("```python\n"));
        assert_eq!(d.code_extent(Utf16Range { start: 14, end: 15 }).start, 4);
        let choices = code_language_choices();
        assert!(choices.len() > 150);
        assert!(choices[0].common && choices[0].token == "rust" && !choices.last().unwrap().common);
        assert!(builtin_themes()[1].syntax.keyword.r > 0xB0);
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
    fn focus_and_parts_of_speech_cross_the_boundary() {
        let d = Document::new("\u{1F389} One. Two **b**\n\nNext.".into());
        let at = Utf16Range { start: 9, end: 9 };
        let f = d.focus_range(at, FocusScope::Sentence);
        assert_eq!(f, [Utf16Range { start: 8, end: 17 }]);
        let st = d.selection_state(at, None, true, Some(FocusScope::Paragraph));
        assert_eq!(st.focus, Some(vec![Utf16Range { start: 0, end: 17 }]));
        assert!(st.concealment.is_some());
        let units = d.pos_units(None);
        assert_eq!(units.len(), 2);
        assert_eq!(pos_joined_len(units[0].clone()), 13);
        let tags = pos_map_tags(units[0].clone(), vec![PosTag { range: Utf16Range { start: 3, end: 6 }, class: PosClass::Noun }]);
        assert_eq!(tags, [PosTag { range: Utf16Range { start: 3, end: 6 }, class: PosClass::Noun }]);
    }

    #[test]
    fn replace_error_maps() {
        let d = Document::new("\u{1F389}".into());
        assert_eq!(d.replace(Utf16Range { start: 1, end: 1 }, "x".into()), Err(EditError::NotOnCodePointBoundary));
        let u = d.replace(Utf16Range { start: 2, end: 2 }, "*a*".into()).unwrap();
        assert_eq!(u.revision, 1);
        assert_eq!(d.spans(None).len(), 3);
    }

    #[test]
    fn rendering_crosses_the_boundary() {
        let d = Document::new("# T\n\n```rust\nlet a = 1;\n```\n\nbody \u{1F389}\n".into());
        let opts = RenderOptions {
            source_lines: true,
            standalone: false,
            sanitize: false,
            highlight: true,
            fallback_title: String::new(),
            style: None,
            image_sizes: vec![ImageSize { destination: "p.png".into(), width: 10, height: 20 }],
        };
        let h = d.render_html(opts.clone());
        assert!(h.contains("<h1 id=\"t\" data-line=\"0\">T</h1>") && h.contains("s-storage"), "{h}");
        // The fragment's range is in UTF-16 units: the emoji is two.
        let frag = d.render_html_fragment(Utf16Range { start: 29, end: 34 }, opts.clone());
        assert_eq!(frag, "<p data-line=\"6\">body \u{1F389}</p>\n", "{frag}");
        let theme = theme_by_id("dark".into()).unwrap();
        let typography = Typography {
            font_family: "serif".into(),
            mono_family: "monospace".into(),
            font_size_px: 18.0,
            line_height: 1.5,
            measure_ch: 70.0,
        };
        let css = preview_css(theme.clone(), typography.clone());
        assert!(css.contains("max-width: 70ch") && css.contains("@media print"));
        let page = d.render_html(RenderOptions { standalone: true, style: Some(PreviewStyle { theme, typography }), ..opts });
        assert!(page.starts_with("<!DOCTYPE html>") && page.contains("max-width: 70ch"));
        assert_eq!(heading_slug("Hello, World".into()), "hello-world");
        warm_up_highlighting();
    }
}
