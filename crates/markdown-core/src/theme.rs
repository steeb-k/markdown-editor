//! Theme palettes: data only. The shell maps the roles onto its own widgets and attributes.
//!
//! The built-in themes are TOML files embedded at compile time (`themes/*.toml`). "System"
//! (follow the OS appearance) is a shell concern: it picks Light or Dark.

use serde::de::{self, Deserializer};
use serde::Deserialize;

/// An sRGB color with alpha, 8 bits per channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    pub fn from_hex(s: &str) -> Option<Self> {
        let h = s.strip_prefix('#')?;
        if !h.is_ascii() || !(h.len() == 6 || h.len() == 8) {
            return None;
        }
        let byte = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
        Some(Self { r: byte(0)?, g: byte(2)?, b: byte(4)?, a: if h.len() == 8 { byte(6)? } else { 255 } })
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    pub fn to_hex(self) -> String {
        if self.a == 255 {
            format!("#{:02X}{:02X}{:02X}", self.r, self.g, self.b)
        } else {
            format!("#{:02X}{:02X}{:02X}{:02X}", self.r, self.g, self.b, self.a)
        }
    }

    /// WCAG relative luminance (alpha ignored).
    pub fn luminance(self) -> f64 {
        let f = |c: u8| {
            let c = c as f64 / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * f(self.r) + 0.7152 * f(self.g) + 0.0722 * f(self.b)
    }

    /// Source-over compositing of `self` on an opaque `backdrop`.
    pub fn over(self, backdrop: Color) -> Color {
        let a = self.a as f64 / 255.0;
        let mix = |f: u8, b: u8| (f as f64 * a + b as f64 * (1.0 - a)).round() as u8;
        Color::rgb(mix(self.r, backdrop.r), mix(self.g, backdrop.g), mix(self.b, backdrop.b))
    }
}

/// WCAG 2 contrast ratio between two colors (1.0 to 21.0).
pub fn contrast_ratio(a: Color, b: Color) -> f64 {
    let (la, lb) = (a.luminance(), b.luminance());
    let (hi, lo) = if la >= lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

impl<'de> Deserialize<'de> for Color {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Color::from_hex(&s).ok_or_else(|| de::Error::custom(format!("invalid color {s:?} (want #RRGGBB or #RRGGBBAA)")))
    }
}

/// Every color role of a theme.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Colors {
    pub background: Color,
    pub text: Color,
    /// Syntax characters (`**`, `#`, `](url)`); deliberately dim.
    pub markup: Color,
    pub heading: Color,
    pub link: Color,
    pub code_text: Color,
    pub code_background: Color,
    /// Text of block quotes.
    pub quote: Color,
    pub selection: Color,
    pub caret: Color,
    /// Everything outside the focus range; deliberately dim.
    pub focus_dim: Color,
    pub pos_noun: Color,
    pub pos_verb: Color,
    pub pos_adjective: Color,
    pub pos_adverb: Color,
    pub pos_conjunction: Color,
    pub author_ai: Color,
    pub author_reference: Color,
    /// Thematic breaks and the block quote bar.
    pub rule: Color,
    pub table_border: Color,
}

impl Colors {
    /// `(role name, color)` for every role, in a fixed order.
    pub fn all(&self) -> Vec<(&'static str, Color)> {
        vec![
            ("background", self.background),
            ("text", self.text),
            ("markup", self.markup),
            ("heading", self.heading),
            ("link", self.link),
            ("code_text", self.code_text),
            ("code_background", self.code_background),
            ("quote", self.quote),
            ("selection", self.selection),
            ("caret", self.caret),
            ("focus_dim", self.focus_dim),
            ("pos_noun", self.pos_noun),
            ("pos_verb", self.pos_verb),
            ("pos_adjective", self.pos_adjective),
            ("pos_adverb", self.pos_adverb),
            ("pos_conjunction", self.pos_conjunction),
            ("author_ai", self.author_ai),
            ("author_reference", self.author_reference),
            ("rule", self.rule),
            ("table_border", self.table_border),
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub is_dark: bool,
    pub colors: Colors,
}

impl Theme {
    /// Parse a theme from TOML (`id`, `name`, `is_dark` and a `[colors]` table with every role).
    pub fn from_toml(src: &str) -> Result<Theme, String> {
        toml::from_str(src).map_err(|e| e.to_string())
    }
}

const BUILTIN: [&str; 3] = [
    include_str!("../themes/light.toml"),
    include_str!("../themes/dark.toml"),
    include_str!("../themes/sepia.toml"),
];

/// Light, Dark and Sepia, in that order.
pub fn builtin_themes() -> Vec<Theme> {
    BUILTIN
        .iter()
        .map(|src| Theme::from_toml(src).expect("built-in theme is valid (checked by the theme tests)"))
        .collect()
}

pub fn theme_by_id(id: &str) -> Option<Theme> {
    builtin_themes().into_iter().find(|t| t.id == id)
}
