//! UniFFI surface of `markdown_core::template`. Mirrors the model as records and enums (the spec is a record tree, so
//! the Swift inspector edits plain values) and forwards the calls; no logic. The names carry a `Template` prefix where
//! a bare one could clash with AppKit or SwiftUI (`Length`, `Border`, `Color`, ...).

use markdown_core::template as ct;
use markdown_core::template::ElementKind as CoreKind;

use crate::{Theme, Typography};

/// A fieldless enum and its two conversions to and from the core's.
macro_rules! mirror_enum {
    ($(#[$meta:meta])* $name:ident = $core:ty { $($variant:ident),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
        pub enum $name {
            $($variant),+
        }

        impl From<$core> for $name {
            fn from(v: $core) -> Self {
                match v {
                    $(<$core>::$variant => $name::$variant),+
                }
            }
        }

        impl From<$name> for $core {
            fn from(v: $name) -> Self {
                match v {
                    $($name::$variant => <$core>::$variant),+
                }
            }
        }
    };
}

mirror_enum! {
    /// A kind of element a template styles (`core::template::ElementKind`).
    TemplateElementKind = CoreKind {
        Body, H1, H2, H3, H4, H5, H6, Paragraph, Link, Emphasis, Strong, InlineCode, CodeBlock, BlockQuote, BulletList,
        NumberedList, TaskItem, Table, TableHeader, Rule, Image, Footnotes, Tag
    }
}
mirror_enum! { TemplateUnit = ct::Unit { Em, Px, Pt } }
mirror_enum! {
    /// One of the preview's theme variables.
    TemplateThemeColor = ct::ThemeColor { Text, Heading, Link, Quote, Rule, Border, CodeText, CodeBackground, Background, Markup }
}
mirror_enum! { TemplateAlign = ct::Align { Left, Center, Right, Justify } }
mirror_enum! { TemplateTransform = ct::Transform { None, Uppercase, SmallCaps } }
mirror_enum! { TemplateDecoration = ct::Decoration { None, Underline } }
mirror_enum! { TemplateSide = ct::Side { Top, Right, Bottom, Left } }
mirror_enum! { TemplateBorderStyle = ct::BorderStyle { Solid, Dashed, Dotted } }
mirror_enum! { TemplateMarker = ct::Marker { Disc, Circle, Square, Dash, Decimal, LowerAlpha, LowerRoman } }

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TemplateLength {
    pub value: f64,
    pub unit: TemplateUnit,
}

/// A colour: a theme variable (follows the appearance) or a fixed sRGB one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TemplateColor {
    Theme { name: TemplateThemeColor },
    Fixed { r: u8, g: u8, b: u8 },
}

/// A font family: the editor's chosen faces, or a name (or a comma-separated stack).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TemplateFont {
    Body,
    Mono,
    Named { name: String },
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TemplateBorder {
    pub side: TemplateSide,
    pub style: TemplateBorderStyle,
    pub width: TemplateLength,
    pub color: TemplateColor,
}

/// What a template says about one kind of element; unset fields are "as the Default template".
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct TemplateElementStyle {
    #[uniffi(default = None)]
    pub font_family: Option<TemplateFont>,
    #[uniffi(default = None)]
    pub font_size: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub weight: Option<u16>,
    #[uniffi(default = None)]
    pub italic: Option<bool>,
    #[uniffi(default = None)]
    pub color: Option<TemplateColor>,
    #[uniffi(default = None)]
    pub background: Option<TemplateColor>,
    #[uniffi(default = None)]
    pub space_above: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub space_below: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub line_height: Option<f64>,
    #[uniffi(default = None)]
    pub align: Option<TemplateAlign>,
    #[uniffi(default = None)]
    pub indent: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub letter_spacing: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub transform: Option<TemplateTransform>,
    #[uniffi(default = None)]
    pub decoration: Option<TemplateDecoration>,
    #[uniffi(default = None)]
    pub border: Option<TemplateBorder>,
    #[uniffi(default = None)]
    pub radius: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub numbered: Option<bool>,
    #[uniffi(default = None)]
    pub marker: Option<TemplateMarker>,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct TemplatePage {
    #[uniffi(default = None)]
    pub measure_ch: Option<f64>,
    #[uniffi(default = None)]
    pub side_padding: Option<TemplateLength>,
    #[uniffi(default = None)]
    pub background: Option<TemplateColor>,
    #[uniffi(default = None)]
    pub align: Option<TemplateAlign>,
}

/// One element kind's style. Only kinds with something set are listed, in `element_kinds()` order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TemplateElement {
    pub kind: TemplateElementKind,
    pub style: TemplateElementStyle,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct TemplateSpec {
    pub page: TemplatePage,
    #[uniffi(default = [])]
    pub elements: Vec<TemplateElement>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TemplateMeta {
    pub name: String,
    pub author: String,
    pub version: String,
    pub description: String,
}

/// A template's `template.toml`: metadata and structured styles.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct Template {
    pub meta: TemplateMeta,
    pub spec: TemplateSpec,
}

/// What the inspector and the sample page need to know about an element kind.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TemplateElementInfo {
    pub kind: TemplateElementKind,
    /// The name the inspector's popup shows.
    pub name: String,
    /// The table's name in `template.toml` (`h1`, `code_block`).
    pub key: String,
    /// The CSS selector of the kind in the preview's HTML.
    pub selector: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum TemplateError {
    /// Not TOML.
    Syntax { message: String },
    /// A value that does not fit its key; `key` is the full path (`elements.h1.font_size`).
    Value { key: String, message: String },
}

impl std::fmt::Display for TemplateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        ct::TemplateError::from(self.clone()).fmt(f)
    }
}

impl std::error::Error for TemplateError {}

// ----- conversions (field-by-field, no logic) -----------------------------------------------------------------

impl From<ct::TemplateError> for TemplateError {
    fn from(e: ct::TemplateError) -> Self {
        match e {
            ct::TemplateError::Syntax(message) => TemplateError::Syntax { message },
            ct::TemplateError::Value { key, message } => TemplateError::Value { key, message },
        }
    }
}

impl From<TemplateError> for ct::TemplateError {
    fn from(e: TemplateError) -> Self {
        match e {
            TemplateError::Syntax { message } => ct::TemplateError::Syntax(message),
            TemplateError::Value { key, message } => ct::TemplateError::Value { key, message },
        }
    }
}

impl From<ct::Length> for TemplateLength {
    fn from(l: ct::Length) -> Self {
        TemplateLength { value: l.value, unit: l.unit.into() }
    }
}

impl From<TemplateLength> for ct::Length {
    fn from(l: TemplateLength) -> Self {
        ct::Length { value: l.value, unit: l.unit.into() }
    }
}

impl From<ct::ColorRef> for TemplateColor {
    fn from(c: ct::ColorRef) -> Self {
        match c {
            ct::ColorRef::Theme(name) => TemplateColor::Theme { name: name.into() },
            ct::ColorRef::Fixed(ct::Rgb(r, g, b)) => TemplateColor::Fixed { r, g, b },
        }
    }
}

impl From<TemplateColor> for ct::ColorRef {
    fn from(c: TemplateColor) -> Self {
        match c {
            TemplateColor::Theme { name } => ct::ColorRef::Theme(name.into()),
            TemplateColor::Fixed { r, g, b } => ct::ColorRef::Fixed(ct::Rgb(r, g, b)),
        }
    }
}

impl From<ct::FontFamily> for TemplateFont {
    fn from(f: ct::FontFamily) -> Self {
        match f {
            ct::FontFamily::Body => TemplateFont::Body,
            ct::FontFamily::Mono => TemplateFont::Mono,
            ct::FontFamily::Named(name) => TemplateFont::Named { name },
        }
    }
}

impl From<TemplateFont> for ct::FontFamily {
    fn from(f: TemplateFont) -> Self {
        match f {
            TemplateFont::Body => ct::FontFamily::Body,
            TemplateFont::Mono => ct::FontFamily::Mono,
            TemplateFont::Named { name } => ct::FontFamily::Named(name),
        }
    }
}

impl From<ct::Border> for TemplateBorder {
    fn from(b: ct::Border) -> Self {
        TemplateBorder { side: b.side.into(), style: b.style.into(), width: b.width.into(), color: b.color.into() }
    }
}

impl From<TemplateBorder> for ct::Border {
    fn from(b: TemplateBorder) -> Self {
        ct::Border { side: b.side.into(), style: b.style.into(), width: b.width.into(), color: b.color.into() }
    }
}

impl From<ct::ElementStyle> for TemplateElementStyle {
    fn from(s: ct::ElementStyle) -> Self {
        TemplateElementStyle {
            font_family: s.font_family.map(Into::into),
            font_size: s.font_size.map(Into::into),
            weight: s.weight,
            italic: s.italic,
            color: s.color.map(Into::into),
            background: s.background.map(Into::into),
            space_above: s.space_above.map(Into::into),
            space_below: s.space_below.map(Into::into),
            line_height: s.line_height,
            align: s.align.map(Into::into),
            indent: s.indent.map(Into::into),
            letter_spacing: s.letter_spacing.map(Into::into),
            transform: s.transform.map(Into::into),
            decoration: s.decoration.map(Into::into),
            border: s.border.map(Into::into),
            radius: s.radius.map(Into::into),
            numbered: s.numbered,
            marker: s.marker.map(Into::into),
        }
    }
}

impl From<TemplateElementStyle> for ct::ElementStyle {
    fn from(s: TemplateElementStyle) -> Self {
        ct::ElementStyle {
            font_family: s.font_family.map(Into::into),
            font_size: s.font_size.map(Into::into),
            weight: s.weight,
            italic: s.italic,
            color: s.color.map(Into::into),
            background: s.background.map(Into::into),
            space_above: s.space_above.map(Into::into),
            space_below: s.space_below.map(Into::into),
            line_height: s.line_height,
            align: s.align.map(Into::into),
            indent: s.indent.map(Into::into),
            letter_spacing: s.letter_spacing.map(Into::into),
            transform: s.transform.map(Into::into),
            decoration: s.decoration.map(Into::into),
            border: s.border.map(Into::into),
            radius: s.radius.map(Into::into),
            numbered: s.numbered,
            marker: s.marker.map(Into::into),
        }
    }
}

impl From<ct::PageStyle> for TemplatePage {
    fn from(p: ct::PageStyle) -> Self {
        TemplatePage {
            measure_ch: p.measure_ch,
            side_padding: p.side_padding.map(Into::into),
            background: p.background.map(Into::into),
            align: p.align.map(Into::into),
        }
    }
}

impl From<TemplatePage> for ct::PageStyle {
    fn from(p: TemplatePage) -> Self {
        ct::PageStyle {
            measure_ch: p.measure_ch,
            side_padding: p.side_padding.map(Into::into),
            background: p.background.map(Into::into),
            align: p.align.map(Into::into),
        }
    }
}

impl From<ct::TemplateSpec> for TemplateSpec {
    fn from(s: ct::TemplateSpec) -> Self {
        TemplateSpec {
            page: s.page.into(),
            elements: s.elements.into_iter().map(|(k, style)| TemplateElement { kind: k.into(), style: style.into() }).collect(),
        }
    }
}

impl From<TemplateSpec> for ct::TemplateSpec {
    fn from(s: TemplateSpec) -> Self {
        // A kind listed twice: the last entry wins.
        ct::TemplateSpec { page: s.page.into(), elements: s.elements.into_iter().map(|e| (e.kind.into(), e.style.into())).collect() }
    }
}

impl From<ct::TemplateMeta> for TemplateMeta {
    fn from(m: ct::TemplateMeta) -> Self {
        TemplateMeta { name: m.name, author: m.author, version: m.version, description: m.description }
    }
}

impl From<TemplateMeta> for ct::TemplateMeta {
    fn from(m: TemplateMeta) -> Self {
        ct::TemplateMeta { name: m.name, author: m.author, version: m.version, description: m.description }
    }
}

impl From<ct::Template> for Template {
    fn from(t: ct::Template) -> Self {
        Template { meta: t.meta.into(), spec: t.spec.into() }
    }
}

impl From<Template> for ct::Template {
    fn from(t: Template) -> Self {
        ct::Template { meta: t.meta.into(), spec: t.spec.into() }
    }
}

// ----- functions --------------------------------------------------------------------------------------------

/// The stylesheet of a template: the preview's base for `theme` set in `typography`, the template's rules, then the
/// print block. The shell appends the template's `custom.css`. An empty spec gives `preview_css`.
#[uniffi::export]
pub fn template_css(spec: TemplateSpec, theme: Theme, typography: Typography) -> String {
    ct::template_css(&spec.into(), &theme.into(), &typography.into())
}

/// Reads a `template.toml`. Unknown keys are ignored; a bad value is an error naming its key.
#[uniffi::export]
pub fn parse_template(toml: String) -> Result<Template, TemplateError> {
    ct::Template::parse(&toml).map(Template::from).map_err(TemplateError::from)
}

/// The `template.toml` text of a template (stable key order; reading it back gives the template).
#[uniffi::export]
pub fn template_toml(template: Template) -> String {
    ct::Template::from(template).to_toml()
}

/// Every element kind, in the order of the rules and the inspector's popup, with its name, TOML key and selector.
#[uniffi::export]
pub fn element_kinds() -> Vec<TemplateElementInfo> {
    CoreKind::all()
        .into_iter()
        .map(|k| TemplateElementInfo {
            kind: k.into(),
            name: k.name().to_owned(),
            key: k.key().to_owned(),
            selector: k.selector().to_owned(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typography() -> Typography {
        let t = markdown_core::Typography::default();
        Typography { font_family: t.font_family, mono_family: t.mono_family, font_size_px: t.font_size_px, line_height: t.line_height, measure_ch: t.measure_ch }
    }

    #[test]
    fn the_model_crosses_and_comes_back() {
        let t = parse_template(
            "[template]\nname = \"T\"\n[page]\nalign = \"center\"\n[elements.h1]\ncolor = \"theme:link\"\nnumbered = true\n\
             [elements.rule]\nborder = { side = \"top\", style = \"dashed\", width = \"1px\", color = \"#102030\" }\n"
                .to_owned(),
        )
        .unwrap();
        assert_eq!(t.meta.name, "T");
        assert_eq!(t.spec.page.align, Some(TemplateAlign::Center));
        assert_eq!(t.spec.elements.len(), 2);
        assert_eq!(t.spec.elements[0].kind, TemplateElementKind::H1);
        assert_eq!(t.spec.elements[0].style.color, Some(TemplateColor::Theme { name: TemplateThemeColor::Link }));
        assert_eq!(parse_template(template_toml(t.clone())).unwrap(), t);
        let css = template_css(t.spec, crate::builtin_themes().remove(0), typography());
        assert!(css.contains("hr { border-top: 1px dashed #102030; }"));
        assert!(matches!(parse_template("[elements.h1]\nweight = 5".into()), Err(TemplateError::Value { key, .. }) if key == "elements.h1.weight"));
        assert_eq!(element_kinds().len(), 23);
    }
}
