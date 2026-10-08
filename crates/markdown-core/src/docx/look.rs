//! What the template says, resolved for Word: fonts as one installed name, lengths in points, colours as `RRGGBB` in the
//! Light theme (the printed look), and the page. `styles.xml` and the body are both built from this, so a heading is the
//! same size in the style that sets it and in the table that measures a picture against the text width.

use crate::preview_css::Typography;
use crate::template::{Align, Border, BorderStyle, ColorRef, ElementKind, ElementStyle, FontFamily, Length, Side, ThemeColor, Transform, Unit};
use crate::theme::{builtin_themes, Color, Theme};

use super::xml::twips;
use super::DocxOptions;

/// The body text size when the template does not say: the print block's 11 pt.
pub(crate) const DEFAULT_BODY_PT: f64 = 11.0;

/// The page in twips (twentieths of a point).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Page {
    pub width: i64,
    pub height: i64,
    pub margin_x: i64,
    pub margin_y: i64,
}

impl Page {
    /// The width of the text column.
    pub fn text_width(&self) -> i64 {
        self.width - 2 * self.margin_x
    }

    /// The height of the text column.
    pub fn text_height(&self) -> i64 {
        self.height - 2 * self.margin_y
    }
}

/// How a run of text is set.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Face {
    pub family: String,
    pub size_pt: f64,
    pub bold: bool,
    pub italic: bool,
    pub color: String,
    pub caps: bool,
    pub small_caps: bool,
    pub underline: bool,
    /// Extra space between letters, in points.
    pub spacing_pt: Option<f64>,
}

/// How a paragraph is set. Lengths in points.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Para {
    pub align: Option<&'static str>,
    pub before_pt: f64,
    pub after_pt: f64,
    /// A multiple of the font size.
    pub line: Option<f64>,
    pub first_line_pt: Option<f64>,
    pub left_pt: f64,
    pub keep_with_next: bool,
    pub shade: Option<String>,
    /// (side, line, size in eighths of a point, colour, space in points).
    pub borders: Vec<(&'static str, &'static str, i64, String, i64)>,
}

pub(crate) struct Look<'o> {
    pub opts: &'o DocxOptions,
    pub theme: Theme,
    pub body_pt: f64,
}

impl<'o> Look<'o> {
    pub fn new(opts: &'o DocxOptions) -> Self {
        let theme = builtin_themes().remove(0);
        let mut look = Look { opts, theme, body_pt: DEFAULT_BODY_PT };
        if let Some(size) = look.element(ElementKind::Body).and_then(|e| e.font_size) {
            look.body_pt = look.pt(size, DEFAULT_BODY_PT).max(6.0);
        }
        look
    }

    pub fn element(&self, kind: ElementKind) -> Option<&ElementStyle> {
        self.opts.spec.elements.get(&kind)
    }

    /// A length in points; `em_base` is what an `em` is of.
    pub fn pt(&self, len: Length, em_base: f64) -> f64 {
        match len.unit {
            Unit::Em => len.value * em_base,
            // A CSS pixel is 3/4 of a point.
            Unit::Px => len.value * 0.75,
            Unit::Pt => len.value,
        }
    }

    // ----- colours -----------------------------------------------------------------------------------------

    fn theme_color(&self, c: ThemeColor) -> Color {
        let k = &self.theme.colors;
        match c {
            ThemeColor::Text => k.text,
            ThemeColor::Heading => k.heading,
            ThemeColor::Link => k.link,
            ThemeColor::Quote => k.quote,
            ThemeColor::Rule => k.rule,
            ThemeColor::Border => k.table_border,
            ThemeColor::CodeText => k.code_text,
            ThemeColor::CodeBackground => k.code_background,
            ThemeColor::Background => k.background,
            ThemeColor::Markup => k.markup,
        }
    }

    /// `RRGGBB` of a template colour; theme colours as the Light theme has them.
    pub fn color(&self, c: ColorRef) -> String {
        match c {
            ColorRef::Fixed(rgb) => format!("{:02X}{:02X}{:02X}", rgb.0, rgb.1, rgb.2),
            ColorRef::Theme(t) => self.hex(self.theme_color(t)),
        }
    }

    pub fn theme_hex(&self, t: ThemeColor) -> String {
        self.hex(self.theme_color(t))
    }

    fn hex(&self, c: Color) -> String {
        let c = c.over(self.theme.colors.background);
        format!("{:02X}{:02X}{:02X}", c.r, c.g, c.b)
    }

    // ----- fonts -------------------------------------------------------------------------------------------

    pub fn body_family(&self) -> String {
        first_family(&self.opts.typography.font_family, false)
    }

    pub fn mono_family(&self) -> String {
        first_family(&self.opts.typography.mono_family, true)
    }

    pub fn family(&self, f: &FontFamily, code: bool) -> String {
        match f {
            FontFamily::Body => self.body_family(),
            FontFamily::Mono => self.mono_family(),
            FontFamily::Named(stack) => first_family(stack, code),
        }
    }

    /// Whether the editor's body face is the code face too (a monospaced body): code is then set at the body's size.
    pub fn body_is_mono(&self) -> bool {
        let t: &Typography = &self.opts.typography;
        t.font_family == t.mono_family
    }

    // ----- styles ------------------------------------------------------------------------------------------

    /// Applies what `e` sets to a face and a paragraph. `parent_pt` is what an `em` of font size is of.
    pub fn apply(&self, e: &ElementStyle, kind: ElementKind, face: &mut Face, para: &mut Para, parent_pt: f64) {
        let code = matches!(kind, ElementKind::InlineCode | ElementKind::CodeBlock);
        if let Some(f) = &e.font_family {
            face.family = self.family(f, code);
        }
        if let Some(s) = e.font_size {
            face.size_pt = self.pt(s, parent_pt).max(1.0);
        }
        if let Some(w) = e.weight {
            face.bold = w >= 600;
        }
        if let Some(i) = e.italic {
            face.italic = i;
        }
        if let Some(c) = e.color {
            face.color = self.color(c);
        }
        match e.transform {
            Some(Transform::Uppercase) => {
                face.caps = true;
                face.small_caps = false;
            }
            Some(Transform::SmallCaps) => {
                face.small_caps = true;
                face.caps = false;
            }
            Some(Transform::None) => {
                face.caps = false;
                face.small_caps = false;
            }
            None => {}
        }
        if let Some(d) = e.decoration {
            face.underline = d == crate::template::Decoration::Underline;
        }
        if let Some(s) = e.letter_spacing {
            face.spacing_pt = Some(self.pt(s, face.size_pt));
        }
        if let Some(b) = e.background {
            para.shade = Some(self.color(b));
        }
        if let Some(v) = e.space_above {
            para.before_pt = self.pt(v, face.size_pt);
        }
        if let Some(v) = e.space_below {
            para.after_pt = self.pt(v, face.size_pt);
        }
        if let Some(v) = e.line_height {
            para.line = Some(v);
        }
        if let Some(a) = e.align {
            para.align = Some(align(a));
        }
        if let Some(v) = e.indent {
            para.first_line_pt = Some(self.pt(v, face.size_pt));
        }
        if let Some(b) = e.border {
            let entry = self.border(b);
            para.borders.retain(|x| x.0 != entry.0);
            para.borders.push(entry);
        }
    }

    /// A template border as Word's (side, line, eighths of a point, colour, space).
    pub fn border(&self, b: Border) -> (&'static str, &'static str, i64, String, i64) {
        let side = match b.side {
            Side::Top => "top",
            Side::Right => "right",
            Side::Bottom => "bottom",
            Side::Left => "left",
        };
        let line = match b.style {
            BorderStyle::Solid => "single",
            BorderStyle::Dashed => "dashed",
            BorderStyle::Dotted => "dotted",
        };
        let size = (self.pt(b.width, self.body_pt) * 8.0).round().clamp(2.0, 96.0) as i64;
        (side, line, size, self.color(b.color), 1)
    }

    /// The page: Letter unless the shell gives the paper, the margins from the template's column.
    pub fn page(&self) -> Page {
        let o = self.opts;
        let width_pt = if o.page_width_pt > 0.0 { o.page_width_pt } else { 612.0 };
        let height_pt = if o.page_height_pt > 0.0 { o.page_height_pt } else { 792.0 };
        let mut margin_x = 72.0_f64;
        let page = &o.spec.page;
        // A column of N characters is about N times half an em wide; centred on the page, within sensible margins.
        if let Some(ch) = page.measure_ch {
            margin_x = ((width_pt - ch * 0.55 * self.body_pt) / 2.0).clamp(54.0, 144.0);
        }
        if let Some(pad) = page.side_padding {
            margin_x += self.pt(pad, self.body_pt).max(0.0);
        }
        // Never leave less than a narrow column.
        margin_x = margin_x.min((width_pt - 200.0).max(0.0) / 2.0);
        Page { width: twips(width_pt), height: twips(height_pt), margin_x: twips(margin_x), margin_y: twips(72.0) }
    }
}

pub(crate) fn align(a: Align) -> &'static str {
    match a {
        Align::Left => "left",
        Align::Center => "center",
        Align::Right => "right",
        Align::Justify => "both",
    }
}

/// The first usable family name of a CSS stack: not one of the system aliases a browser resolves (`-apple-system`,
/// `ui-monospace`) and not a bare generic family, which stand for a face Word has to be told by name.
pub(crate) fn first_family(stack: &str, code: bool) -> String {
    const ALIASES: &[&str] =
        &["-apple-system", "blinkmacsystemfont", "system-ui", "ui-sans-serif", "ui-serif", "ui-monospace", "ui-rounded", "sfmono-regular"];
    let mut generic = None;
    for part in stack.split(',') {
        let name = part.trim().trim_matches(|c| c == '"' || c == '\'').trim();
        let lower = name.to_ascii_lowercase();
        if name.is_empty() || ALIASES.contains(&lower.as_str()) {
            continue;
        }
        match lower.as_str() {
            "serif" => generic = generic.or(Some("Times New Roman")),
            "sans-serif" => generic = generic.or(Some("Arial")),
            "monospace" => generic = generic.or(Some("Courier New")),
            "cursive" | "fantasy" => {}
            _ => return name.to_owned(),
        }
    }
    generic.unwrap_or(if code { "Courier New" } else { "Arial" }).to_owned()
}
