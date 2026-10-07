//! Templates: the look of a document outside the editor (the preview, PDF, print and the HTML and rich-text copies).
//!
//! A template is a `template.toml` (metadata and structured styles; this module) and an optional `custom.css` that the
//! shell appends untouched. The structured styles are a [`TemplateSpec`]: a few page settings and one [`ElementStyle`]
//! per [`ElementKind`], every field optional, unset meaning "as the Default template". [`template_css`] writes the
//! preview's stylesheet and then one rule per element kind with set fields, so an empty spec gives exactly
//! [`crate::preview_css`] and a template only ever adds rules after the base, where the cascade lets them win.
//!
//! The renderer knows nothing of templates: the selectors ([`ElementKind::selector`]) are the tags and classes its HTML
//! already has. The TOML is read and written by hand rather than through serde so that a bad value is reported with
//! its full key (`elements.h1.font_size`) and so that the key order is ours: `[template]`, `[page]`, then the elements
//! in [`ElementKind::all`] order, each with its fields in the order of the struct.

use std::collections::BTreeMap;
use std::fmt::{self, Write};

use toml::{Table, Value};

use crate::preview_css::{fmt_num, font_stack, write_base, write_print, Typography};
use crate::theme::Theme;

// ----- small string-named enums --------------------------------------------------------------------------------

/// An enum whose values are written as fixed lower-case words in the TOML (and read back case-insensitively).
macro_rules! word_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident => $word:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum $name {
            $($variant),+
        }

        impl $name {
            /// Every value, in declaration order.
            pub const ALL: &'static [$name] = &[$($name::$variant),+];

            /// The word the TOML and the Templates window use.
            pub fn word(self) -> &'static str {
                match self {
                    $($name::$variant => $word),+
                }
            }

            /// The value written as `s` (any case, surrounding space ignored).
            pub fn parse(s: &str) -> Result<Self, String> {
                let s = s.trim().to_ascii_lowercase();
                match s.as_str() {
                    $($word => Ok($name::$variant),)+
                    _ => Err(format!("{s:?} is not one of {}", [$($word),+].join(", "))),
                }
            }
        }
    };
}

word_enum! {
    /// The unit of a [`Length`].
    Unit { Em => "em", Px => "px", Pt => "pt" }
}

word_enum! {
    /// One of the preview's theme variables, as a colour a template may use without fixing it: it follows the
    /// appearance (a light and a dark theme, and the print block's light palette).
    ThemeColor {
        Text => "text",
        Heading => "heading",
        Link => "link",
        Quote => "quote",
        Rule => "rule",
        Border => "border",
        CodeText => "code-text",
        CodeBackground => "code-bg",
        Background => "background",
        Markup => "markup",
    }
}

impl ThemeColor {
    /// The CSS custom property the stylesheet defines for this colour (without `var(...)`).
    pub fn css_var(self) -> &'static str {
        match self {
            ThemeColor::Text => "--text",
            ThemeColor::Heading => "--heading",
            ThemeColor::Link => "--link",
            ThemeColor::Quote => "--quote",
            ThemeColor::Rule => "--rule",
            ThemeColor::Border => "--border",
            ThemeColor::CodeText => "--code-text",
            ThemeColor::CodeBackground => "--code-bg",
            ThemeColor::Background => "--bg",
            ThemeColor::Markup => "--markup",
        }
    }
}

word_enum! {
    /// Text alignment.
    Align { Left => "left", Center => "center", Right => "right", Justify => "justify" }
}

word_enum! {
    /// Letter case: `SmallCaps` is `font-variant: small-caps`.
    Transform { None => "none", Uppercase => "uppercase", SmallCaps => "small-caps" }
}

word_enum! {
    /// Text decoration.
    Decoration { None => "none", Underline => "underline" }
}

word_enum! {
    /// The side of a box a [`Border`] is drawn on.
    Side { Top => "top", Right => "right", Bottom => "bottom", Left => "left" }
}

word_enum! {
    /// The line style of a [`Border`].
    BorderStyle { Solid => "solid", Dashed => "dashed", Dotted => "dotted" }
}

word_enum! {
    /// A list's marker: the first four are for bullet lists, the rest for numbered ones. `Dash` is an en dash and a space.
    Marker {
        Disc => "disc",
        Circle => "circle",
        Square => "square",
        Dash => "dash",
        Decimal => "decimal",
        LowerAlpha => "lower-alpha",
        LowerRoman => "lower-roman",
    }
}

// ----- element kinds ---------------------------------------------------------------------------------------------

/// A kind of element a template styles. The declaration order is the order of the rules in the CSS and of the tables
/// in the TOML.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ElementKind {
    Body,
    H1,
    H2,
    H3,
    H4,
    H5,
    H6,
    Paragraph,
    Link,
    Emphasis,
    Strong,
    InlineCode,
    CodeBlock,
    BlockQuote,
    BulletList,
    NumberedList,
    TaskItem,
    Table,
    TableHeader,
    Rule,
    Image,
    Footnotes,
    Tag,
}

/// (kind, TOML key, display name, selector).
const KINDS: &[(ElementKind, &str, &str, &str)] = &[
    (ElementKind::Body, "body", "Body", "body"),
    (ElementKind::H1, "h1", "Heading 1", "h1"),
    (ElementKind::H2, "h2", "Heading 2", "h2"),
    (ElementKind::H3, "h3", "Heading 3", "h3"),
    (ElementKind::H4, "h4", "Heading 4", "h4"),
    (ElementKind::H5, "h5", "Heading 5", "h5"),
    (ElementKind::H6, "h6", "Heading 6", "h6"),
    (ElementKind::Paragraph, "paragraph", "Paragraph", "p"),
    (ElementKind::Link, "link", "Link", "a"),
    (ElementKind::Emphasis, "emphasis", "Emphasis", "em"),
    (ElementKind::Strong, "strong", "Strong", "strong"),
    (ElementKind::InlineCode, "inline_code", "Inline code", ":not(pre) > code"),
    (ElementKind::CodeBlock, "code_block", "Code block", "pre"),
    (ElementKind::BlockQuote, "block_quote", "Block quote", "blockquote"),
    (ElementKind::BulletList, "bullet_list", "Bullet list", "ul"),
    (ElementKind::NumberedList, "numbered_list", "Numbered list", "ol"),
    (ElementKind::TaskItem, "task_item", "Task item", "li.task-list-item"),
    (ElementKind::Table, "table", "Table", "table"),
    (ElementKind::TableHeader, "table_header", "Table header", "th"),
    (ElementKind::Rule, "rule", "Rule", "hr"),
    (ElementKind::Image, "image", "Image", "img"),
    (ElementKind::Footnotes, "footnotes", "Footnotes", ".footnotes"),
    (ElementKind::Tag, "tag", "Tag", ".tag"),
];

impl ElementKind {
    /// Every kind, in the order the rules are written.
    pub fn all() -> Vec<ElementKind> {
        KINDS.iter().map(|r| r.0).collect()
    }

    fn row(self) -> &'static (ElementKind, &'static str, &'static str, &'static str) {
        KINDS.iter().find(|r| r.0 == self).expect("every kind is in the table")
    }

    /// The table's name in `template.toml` (`h1`, `code_block`, ...).
    pub fn key(self) -> &'static str {
        self.row().1
    }

    /// The name the Templates window shows.
    pub fn name(self) -> &'static str {
        self.row().2
    }

    /// The CSS selector the preview's HTML already carries for this kind (the sample page uses the same one to find
    /// the clicked element).
    pub fn selector(self) -> &'static str {
        self.row().3
    }

    pub fn from_key(key: &str) -> Option<ElementKind> {
        KINDS.iter().find(|r| r.1 == key).map(|r| r.0)
    }

    /// 1 to 6 for the headings.
    pub fn heading_level(self) -> Option<u8> {
        match self {
            ElementKind::H1 => Some(1),
            ElementKind::H2 => Some(2),
            ElementKind::H3 => Some(3),
            ElementKind::H4 => Some(4),
            ElementKind::H5 => Some(5),
            ElementKind::H6 => Some(6),
            _ => None,
        }
    }
}

// ----- values -------------------------------------------------------------------------------------------------------

/// A length: `1.4em`, `12px`, `10pt`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Length {
    pub value: f64,
    pub unit: Unit,
}

impl Length {
    pub const fn new(value: f64, unit: Unit) -> Self {
        Self { value, unit }
    }

    pub fn parse(s: &str) -> Result<Length, String> {
        let s = s.trim().to_ascii_lowercase();
        let s = s.as_str();
        let (number, unit) = [Unit::Em, Unit::Px, Unit::Pt]
            .into_iter()
            .find_map(|u| s.strip_suffix(u.word()).map(|n| (n, u)))
            .ok_or_else(|| format!("{s:?} is not a length (a number and em, px or pt, as in 1.4em)"))?;
        let value: f64 = number.trim().parse().map_err(|_| format!("{s:?} is not a length (a number and em, px or pt)"))?;
        if !value.is_finite() {
            return Err(format!("{s:?} is not a finite length"));
        }
        Ok(Length { value, unit })
    }

    /// As CSS: `1.4em` (to three decimals).
    pub fn css(self) -> String {
        format!("{}{}", fmt_num(self.value), self.unit.word())
    }
}

impl fmt::Display for Length {
    /// As the TOML writes it: every digit of the value, so that it reads back as the same number.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}", self.value, self.unit.word())
    }
}

/// An sRGB colour without alpha, written `#RRGGBB`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Rgb(pub u8, pub u8, pub u8);

impl Rgb {
    pub fn parse(s: &str) -> Result<Rgb, String> {
        let bad = || format!("{s:?} is not a colour (#RRGGBB, or theme:NAME)");
        let h = s.trim().strip_prefix('#').ok_or_else(bad)?;
        if !h.is_ascii() || h.len() != 6 {
            return Err(bad());
        }
        let byte = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).map_err(|_| bad());
        Ok(Rgb(byte(0)?, byte(2)?, byte(4)?))
    }

    pub fn hex(self) -> String {
        format!("#{:02X}{:02X}{:02X}", self.0, self.1, self.2)
    }
}

/// A colour: one of the theme's variables (which follows the appearance) or a fixed one (the same in both
/// appearances and in print).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColorRef {
    Theme(ThemeColor),
    Fixed(Rgb),
}

impl ColorRef {
    /// `theme:link` or `#1A4F9C`.
    pub fn parse(s: &str) -> Result<ColorRef, String> {
        let t = s.trim();
        match t.get(..6).filter(|p| p.eq_ignore_ascii_case("theme:")) {
            Some(_) => ThemeColor::parse(&t[6..]).map(ColorRef::Theme),
            None => Rgb::parse(t).map(ColorRef::Fixed),
        }
    }

    /// The TOML text.
    pub fn text(self) -> String {
        match self {
            ColorRef::Theme(c) => format!("theme:{}", c.word()),
            ColorRef::Fixed(rgb) => rgb.hex(),
        }
    }

    /// The CSS value: `var(--link)` or `#1A4F9C`.
    pub fn css(self) -> String {
        match self {
            ColorRef::Theme(c) => format!("var({})", c.css_var()),
            ColorRef::Fixed(rgb) => rgb.hex(),
        }
    }
}

/// A font family: the editor's chosen faces, or a name (or a comma-separated stack) of the template's own.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FontFamily {
    Body,
    Mono,
    /// A name as the font is installed (`Charter`), a generic family (`serif`) or a stack (`Charter, Georgia, serif`).
    /// `body` and `mono`, in any case, mean the other two when read back, so they are not names.
    Named(String),
}

impl FontFamily {
    pub fn parse(s: &str) -> Result<FontFamily, String> {
        let t = s.trim();
        if t.is_empty() {
            return Err("a font family needs a name".to_owned());
        }
        Ok(match t.to_ascii_lowercase().as_str() {
            "body" => FontFamily::Body,
            "mono" => FontFamily::Mono,
            _ => FontFamily::Named(t.to_owned()),
        })
    }

    pub fn text(&self) -> &str {
        match self {
            FontFamily::Body => "body",
            FontFamily::Mono => "mono",
            FontFamily::Named(n) => n,
        }
    }
}

/// One border: a side, a line style, a width and a colour.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Border {
    pub side: Side,
    pub style: BorderStyle,
    pub width: Length,
    pub color: ColorRef,
}

// ----- the model ----------------------------------------------------------------------------------------------------

/// What a template says about one kind of element. Every field is optional: unset is "as the Default template".
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ElementStyle {
    pub font_family: Option<FontFamily>,
    pub font_size: Option<Length>,
    /// 100 to 900.
    pub weight: Option<u16>,
    pub italic: Option<bool>,
    pub color: Option<ColorRef>,
    pub background: Option<ColorRef>,
    pub space_above: Option<Length>,
    pub space_below: Option<Length>,
    /// A multiple of the font size.
    pub line_height: Option<f64>,
    pub align: Option<Align>,
    /// The first line's indent.
    pub indent: Option<Length>,
    pub letter_spacing: Option<Length>,
    pub transform: Option<Transform>,
    pub decoration: Option<Decoration>,
    pub border: Option<Border>,
    pub radius: Option<Length>,
    /// Headings 1 to 3 only: counters, `1.`, `1.1`, `1.1.1`.
    pub numbered: Option<bool>,
    /// Lists only.
    pub marker: Option<Marker>,
}

impl ElementStyle {
    pub fn is_empty(&self) -> bool {
        *self == ElementStyle::default()
    }
}

/// The page: the text column and what is behind it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PageStyle {
    /// The width of the text column in `ch`; overrides the typography's.
    pub measure_ch: Option<f64>,
    /// The padding left and right of the column.
    pub side_padding: Option<Length>,
    pub background: Option<ColorRef>,
    /// The default text alignment.
    pub align: Option<Align>,
}

impl PageStyle {
    pub fn is_empty(&self) -> bool {
        *self == PageStyle::default()
    }
}

/// Who and what a template is.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TemplateMeta {
    pub name: String,
    pub author: String,
    pub version: String,
    pub description: String,
}

/// The structured styles of a template. The default (empty) spec is the Default template.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TemplateSpec {
    pub page: PageStyle,
    pub elements: BTreeMap<ElementKind, ElementStyle>,
}

/// A template's `template.toml`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Template {
    pub meta: TemplateMeta,
    pub spec: TemplateSpec,
}

/// Why a `template.toml` could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateError {
    /// Not TOML.
    Syntax(String),
    /// A value that does not fit its key (`key` is the full path, such as `elements.h1.font_size`).
    Value { key: String, message: String },
}

impl fmt::Display for TemplateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TemplateError::Syntax(m) => write!(f, "not a valid template: {m}"),
            TemplateError::Value { key, message } => write!(f, "{key}: {message}"),
        }
    }
}

impl std::error::Error for TemplateError {}

// ----- reading --------------------------------------------------------------------------------------------------------

fn value_err(key: String, message: impl Into<String>) -> TemplateError {
    TemplateError::Value { key, message: message.into() }
}

fn path(parent: &str, key: &str) -> String {
    if parent.is_empty() { key.to_owned() } else { format!("{parent}.{key}") }
}

/// A string value under `key`, read by `read`.
fn text<T>(
    t: &Table,
    parent: &str,
    key: &str,
    read: impl FnOnce(&str) -> Result<T, String>,
) -> Result<Option<T>, TemplateError> {
    match t.get(key) {
        None => Ok(None),
        Some(Value::String(s)) => read(s).map(Some).map_err(|m| value_err(path(parent, key), m)),
        Some(_) => Err(value_err(path(parent, key), "expected a string")),
    }
}

/// A number under `key`. TOML has `nan` and `inf`, which no CSS value is (and NaN, not being equal to itself, would make a
/// template differ from its own read-back), so they are refused as a length's are.
fn number(t: &Table, parent: &str, key: &str) -> Result<Option<f64>, TemplateError> {
    match t.get(key) {
        None => Ok(None),
        Some(Value::Float(f)) if !f.is_finite() => Err(value_err(path(parent, key), format!("{f} is not a finite number"))),
        Some(Value::Float(f)) => Ok(Some(*f)),
        Some(Value::Integer(i)) => Ok(Some(*i as f64)),
        Some(_) => Err(value_err(path(parent, key), "expected a number")),
    }
}

fn flag(t: &Table, parent: &str, key: &str) -> Result<Option<bool>, TemplateError> {
    match t.get(key) {
        None => Ok(None),
        Some(Value::Boolean(b)) => Ok(Some(*b)),
        Some(_) => Err(value_err(path(parent, key), "expected true or false")),
    }
}

fn table<'a>(t: &'a Table, parent: &str, key: &str) -> Result<Option<&'a Table>, TemplateError> {
    match t.get(key) {
        None => Ok(None),
        Some(Value::Table(sub)) => Ok(Some(sub)),
        Some(_) => Err(value_err(path(parent, key), "expected a table")),
    }
}

fn read_border(t: &Table, parent: &str) -> Result<Option<Border>, TemplateError> {
    let Some(b) = table(t, parent, "border")? else { return Ok(None) };
    let here = path(parent, "border");
    let missing = |key: &str| value_err(path(&here, key), "missing");
    Ok(Some(Border {
        side: text(b, &here, "side", Side::parse)?.ok_or_else(|| missing("side"))?,
        style: text(b, &here, "style", BorderStyle::parse)?.unwrap_or(BorderStyle::Solid),
        width: text(b, &here, "width", Length::parse)?.ok_or_else(|| missing("width"))?,
        color: text(b, &here, "color", ColorRef::parse)?.ok_or_else(|| missing("color"))?,
    }))
}

fn read_weight(t: &Table, parent: &str) -> Result<Option<u16>, TemplateError> {
    match t.get("weight") {
        None => Ok(None),
        Some(Value::Integer(i)) if (100..=900).contains(i) => Ok(Some(*i as u16)),
        Some(Value::Integer(_)) => Err(value_err(path(parent, "weight"), "expected a weight from 100 to 900")),
        Some(_) => Err(value_err(path(parent, "weight"), "expected a whole number from 100 to 900")),
    }
}

fn read_element(t: &Table, parent: &str) -> Result<ElementStyle, TemplateError> {
    Ok(ElementStyle {
        font_family: text(t, parent, "font_family", FontFamily::parse)?,
        font_size: text(t, parent, "font_size", Length::parse)?,
        weight: read_weight(t, parent)?,
        italic: flag(t, parent, "italic")?,
        color: text(t, parent, "color", ColorRef::parse)?,
        background: text(t, parent, "background", ColorRef::parse)?,
        space_above: text(t, parent, "space_above", Length::parse)?,
        space_below: text(t, parent, "space_below", Length::parse)?,
        line_height: number(t, parent, "line_height")?,
        align: text(t, parent, "align", Align::parse)?,
        indent: text(t, parent, "indent", Length::parse)?,
        letter_spacing: text(t, parent, "letter_spacing", Length::parse)?,
        transform: text(t, parent, "transform", Transform::parse)?,
        decoration: text(t, parent, "decoration", Decoration::parse)?,
        border: read_border(t, parent)?,
        radius: text(t, parent, "radius", Length::parse)?,
        numbered: flag(t, parent, "numbered")?,
        marker: text(t, parent, "marker", Marker::parse)?,
    })
}

impl Template {
    /// Read a `template.toml`. Unknown keys and tables are ignored (a newer app's template still opens); a value that
    /// does not fit its key is an error that names the key.
    pub fn parse(src: &str) -> Result<Template, TemplateError> {
        let doc: Table = toml::from_str(src).map_err(|e| TemplateError::Syntax(e.message().to_owned()))?;
        let mut template = Template::default();
        if let Some(m) = table(&doc, "", "template")? {
            let word = |key: &str| text(m, "template", key, |s| Ok(s.to_owned()));
            template.meta.name = word("name")?.unwrap_or_default();
            template.meta.author = word("author")?.unwrap_or_default();
            template.meta.description = word("description")?.unwrap_or_default();
            // A version is a string, though `version = 1` is a natural thing to type.
            template.meta.version = match m.get("version") {
                None => String::new(),
                Some(Value::String(s)) => s.clone(),
                Some(Value::Integer(i)) => i.to_string(),
                Some(Value::Float(f)) => f.to_string(),
                Some(_) => return Err(value_err("template.version".to_owned(), "expected a string")),
            };
        }
        if let Some(p) = table(&doc, "", "page")? {
            template.spec.page = PageStyle {
                measure_ch: number(p, "page", "measure_ch")?,
                side_padding: text(p, "page", "side_padding", Length::parse)?,
                background: text(p, "page", "background", ColorRef::parse)?,
                align: text(p, "page", "align", Align::parse)?,
            };
        }
        if let Some(elements) = table(&doc, "", "elements")? {
            for kind in ElementKind::all() {
                if let Some(t) = table(elements, "elements", kind.key())? {
                    let style = read_element(t, &path("elements", kind.key()))?;
                    if !style.is_empty() {
                        template.spec.elements.insert(kind, style);
                    }
                }
            }
        }
        Ok(template)
    }

    /// The `template.toml` text: `[template]`, `[page]` when it says anything, then a table per element kind that does,
    /// in [`ElementKind::all`] order. Reading it back gives this template again, and writing that gives the same text.
    pub fn to_toml(&self) -> String {
        let mut out = String::new();
        let quoted = |s: &str| Value::String(s.to_owned()).to_string();
        let m = &self.meta;
        let _ = write!(
            out,
            "[template]\nname = {}\nauthor = {}\nversion = {}\ndescription = {}\n",
            quoted(&m.name),
            quoted(&m.author),
            quoted(&m.version),
            quoted(&m.description)
        );
        let p = &self.spec.page;
        if !p.is_empty() {
            out.push_str("\n[page]\n");
            if let Some(v) = p.measure_ch {
                let _ = writeln!(out, "measure_ch = {}", Value::Float(v));
            }
            if let Some(v) = p.side_padding {
                let _ = writeln!(out, "side_padding = {}", quoted(&v.to_string()));
            }
            if let Some(v) = p.background {
                let _ = writeln!(out, "background = {}", quoted(&v.text()));
            }
            if let Some(v) = p.align {
                let _ = writeln!(out, "align = {}", quoted(v.word()));
            }
        }
        for (kind, s) in &self.spec.elements {
            if s.is_empty() {
                continue;
            }
            let _ = write!(out, "\n[elements.{}]\n", kind.key());
            let mut line = |key: &str, value: String| {
                let _ = writeln!(out, "{key} = {value}");
            };
            if let Some(v) = &s.font_family {
                line("font_family", quoted(v.text()));
            }
            if let Some(v) = s.font_size {
                line("font_size", quoted(&v.to_string()));
            }
            if let Some(v) = s.weight {
                line("weight", v.to_string());
            }
            if let Some(v) = s.italic {
                line("italic", v.to_string());
            }
            if let Some(v) = s.color {
                line("color", quoted(&v.text()));
            }
            if let Some(v) = s.background {
                line("background", quoted(&v.text()));
            }
            if let Some(v) = s.space_above {
                line("space_above", quoted(&v.to_string()));
            }
            if let Some(v) = s.space_below {
                line("space_below", quoted(&v.to_string()));
            }
            if let Some(v) = s.line_height {
                line("line_height", Value::Float(v).to_string());
            }
            if let Some(v) = s.align {
                line("align", quoted(v.word()));
            }
            if let Some(v) = s.indent {
                line("indent", quoted(&v.to_string()));
            }
            if let Some(v) = s.letter_spacing {
                line("letter_spacing", quoted(&v.to_string()));
            }
            if let Some(v) = s.transform {
                line("transform", quoted(v.word()));
            }
            if let Some(v) = s.decoration {
                line("decoration", quoted(v.word()));
            }
            if let Some(b) = s.border {
                line(
                    "border",
                    format!(
                        "{{ side = {}, style = {}, width = {}, color = {} }}",
                        quoted(b.side.word()),
                        quoted(b.style.word()),
                        quoted(&b.width.to_string()),
                        quoted(&b.color.text())
                    ),
                );
            }
            if let Some(v) = s.radius {
                line("radius", quoted(&v.to_string()));
            }
            if let Some(v) = s.numbered {
                line("numbered", v.to_string());
            }
            if let Some(v) = s.marker {
                line("marker", quoted(v.word()));
            }
        }
        out
    }
}

// ----- writing the CSS ------------------------------------------------------------------------------------------

/// The stylesheet for a template: the preview's base (the theme's variables and every element's default look), then the
/// template's page settings and one rule per element kind with set fields, then the print block. An empty spec is
/// byte for byte [`crate::preview_css`]. The shell appends the template's `custom.css` after this.
pub fn template_css(spec: &TemplateSpec, theme: &Theme, typography: &Typography) -> String {
    let mut css = String::with_capacity(9000);
    write_base(&mut css, theme, typography);
    write_rules(&mut css, spec, typography);
    write_print(&mut css, typography);
    css
}

/// The generic family that suits a font a template names, for the fallback after it: code is set in a monospace one, the
/// well-known serif faces in a serif one, anything else in a sans-serif one.
fn generic_for(name: &str, code: bool) -> &'static str {
    const SERIF: &[&str] = &[
        "georgia", "times", "times new roman", "palatino", "charter", "iowan old style", "baskerville", "garamond",
        "cambria", "book antiqua", "new york", "hoefler text", "didot", "bodoni", "cochin", "constantia", "minion",
        "caslon", "century", "sabon",
    ];
    if code {
        "monospace"
    } else if SERIF.contains(&name.to_ascii_lowercase().as_str()) {
        "serif"
    } else {
        "sans-serif"
    }
}

fn family_css(family: &FontFamily, kind: ElementKind, t: &Typography) -> String {
    const GENERIC: &[&str] =
        &["serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded"];
    match family {
        FontFamily::Body => font_stack(&t.font_family),
        FontFamily::Mono => font_stack(&t.mono_family),
        FontFamily::Named(name) => {
            let clean = font_stack(name);
            if clean.contains(',') || GENERIC.contains(&clean.trim().to_ascii_lowercase().as_str()) {
                // A stack the template wrote itself, or a generic family: as it is when it is well formed. A comment
                // opened in it (`Charter, serif /*`) would run to the end of the stylesheet, print block and all, and a
                // quote left open would take the rule's closing brace with it; such a stack is made again from its
                // names, each quoted.
                let well_formed = !clean.contains(['/', '*'])
                    && clean.split(',').all(|part| {
                        let p = part.trim();
                        let inner = [('"', '"'), ('\'', '\'')]
                            .iter()
                            .find_map(|(a, b)| p.strip_prefix(*a).and_then(|q| q.strip_suffix(*b)))
                            .unwrap_or(p);
                        !p.is_empty() && !inner.contains(['"', '\''])
                    });
                if well_formed {
                    return clean;
                }
                let parts: Vec<String> = clean
                    .split(',')
                    .map(|p| p.chars().filter(|c| !matches!(c, '"' | '\'' | '/' | '*')).collect::<String>().trim().to_owned())
                    .filter(|p| !p.is_empty())
                    .map(|p| if GENERIC.contains(&p.to_ascii_lowercase().as_str()) { p } else { format!("\"{p}\"") })
                    .collect();
                return if parts.is_empty() { "sans-serif".to_owned() } else { parts.join(", ") };
            }
            let bare: String = clean.chars().filter(|c| !matches!(c, '"' | '\'')).collect();
            let code = matches!(kind, ElementKind::InlineCode | ElementKind::CodeBlock);
            format!("\"{}\", {}", bare.trim(), generic_for(bare.trim(), code))
        }
    }
}

/// The declarations of one element's set fields, in a fixed order.
fn declarations(kind: ElementKind, s: &ElementStyle, t: &Typography) -> Vec<String> {
    let mut d = Vec::new();
    if let Some(v) = &s.font_family {
        d.push(format!("font-family: {}", family_css(v, kind, t)));
    }
    if let Some(v) = s.font_size {
        d.push(format!("font-size: {}", v.css()));
    }
    if let Some(v) = s.weight {
        d.push(format!("font-weight: {v}"));
    }
    if let Some(v) = s.italic {
        d.push(format!("font-style: {}", if v { "italic" } else { "normal" }));
    }
    if let Some(v) = s.color {
        d.push(format!("color: {}", v.css()));
    }
    if let Some(v) = s.background {
        d.push(format!("background: {}", v.css()));
    }
    if let Some(v) = s.space_above {
        d.push(format!("margin-top: {}", v.css()));
    }
    if let Some(v) = s.space_below {
        d.push(format!("margin-bottom: {}", v.css()));
    }
    if let Some(v) = s.line_height {
        d.push(format!("line-height: {}", fmt_num(v)));
    }
    if let Some(v) = s.align {
        d.push(format!("text-align: {}", v.word()));
    }
    if let Some(v) = s.indent {
        d.push(format!("text-indent: {}", v.css()));
    }
    if let Some(v) = s.letter_spacing {
        d.push(format!("letter-spacing: {}", v.css()));
    }
    match s.transform {
        Some(Transform::None) => d.push("text-transform: none; font-variant: normal".to_owned()),
        Some(Transform::Uppercase) => d.push("text-transform: uppercase".to_owned()),
        Some(Transform::SmallCaps) => d.push("font-variant: small-caps".to_owned()),
        None => {}
    }
    if let Some(v) = s.decoration {
        d.push(format!("text-decoration: {}", v.word()));
    }
    if let Some(b) = s.border {
        d.push(format!("border-{}: {} {} {}", b.side.word(), b.width.css(), b.style.word(), b.color.css()));
    }
    if let Some(v) = s.radius {
        d.push(format!("border-radius: {}", v.css()));
    }
    // Lists: the dash is the marker's content (below); the others are list styles.
    if matches!(kind, ElementKind::BulletList | ElementKind::NumberedList)
        && let Some(m) = s.marker.filter(|m| *m != Marker::Dash)
    {
        d.push(format!("list-style-type: {}", m.word()));
    }
    d
}

fn rule(w: &mut String, selector: &str, declarations: &[String]) {
    if !declarations.is_empty() {
        let _ = writeln!(w, "{selector} {{ {}; }}", declarations.join("; "));
    }
}

/// The page's rules and one rule per element kind with set fields.
fn write_rules(w: &mut String, spec: &TemplateSpec, t: &Typography) {
    let page = &spec.page;
    let mut column = Vec::new();
    if let Some(v) = page.measure_ch {
        column.push(format!("max-width: {}ch", fmt_num(v)));
    }
    if let Some(v) = page.side_padding {
        // Only the sides: the top and bottom padding clear the preview's toolbar and floating controls.
        column.push(format!("padding-left: {}; padding-right: {}", v.css(), v.css()));
    }
    rule(w, ".md", &column);
    if let Some(v) = page.background {
        // The canvas takes the colour of `html` when it has one, and the base gives it one.
        rule(w, "html, body", &[format!("background: {}", v.css())]);
    }
    if let Some(v) = page.align {
        rule(w, "body", &[format!("text-align: {}", v.word())]);
    }

    // Numbered headings: one counter per level on `.md`, bumped by the heading and reset by every shallower one.
    let numbered = |level: u8| {
        let kind = [ElementKind::H1, ElementKind::H2, ElementKind::H3][level as usize - 1];
        spec.elements.get(&kind).and_then(|s| s.numbered) == Some(true)
    };
    if (1..=3).any(numbered) {
        rule(w, ".md", &["counter-reset: md-h1 md-h2 md-h3".to_owned()]);
    }

    for kind in ElementKind::all() {
        let Some(style) = spec.elements.get(&kind) else { continue };
        let mut d = declarations(kind, style, t);
        let level = kind.heading_level().filter(|l| *l <= 3 && numbered(*l));
        if let Some(level) = level {
            d.push(format!("counter-increment: md-h{level}"));
            let deeper: Vec<String> = (level + 1..=3).filter(|l| numbered(*l)).map(|l| format!("md-h{l}")).collect();
            if !deeper.is_empty() {
                d.push(format!("counter-reset: {}", deeper.join(" ")));
            }
        }
        rule(w, kind.selector(), &d);
        if let Some(level) = level {
            // `1. ` for a lone level, `1.1 ` and `1.1.1 ` when the levels above are numbered too.
            let parts: Vec<String> = (1..=level).filter(|l| numbered(*l)).map(|l| format!("counter(md-h{l})")).collect();
            let content = if parts.len() == 1 {
                format!("{} \". \"", parts[0])
            } else {
                format!("{} \" \"", parts.join(" \".\" "))
            };
            rule(w, &format!("{}::before", kind.selector()), &[format!("content: {content}")]);
        }
        match kind {
            ElementKind::CodeBlock => {
                // The code inside a block has its own family and colour in the base: the block's must reach it.
                let mut inner = Vec::new();
                if let Some(v) = &style.font_family {
                    inner.push(format!("font-family: {}", family_css(v, kind, t)));
                }
                if let Some(v) = style.color {
                    inner.push(format!("color: {}", v.css()));
                }
                rule(w, "pre code", &inner);
            }
            ElementKind::BulletList | ElementKind::NumberedList if style.marker == Some(Marker::Dash) => {
                // Task items draw their own box and have no marker to replace.
                rule(w, &format!("{} > li:not(.task-list-item)::marker", kind.selector()), &["content: \"\u{2013} \"".to_owned()]);
            }
            _ => {}
        }
    }
}
