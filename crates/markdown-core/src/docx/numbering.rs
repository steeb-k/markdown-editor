//! `word/numbering.xml`: the bullet list, the numbered list and the numbered headings.
//!
//! Three abstract definitions (bullets with six levels, decimals with six levels, and the headings' outline when the
//! template numbers them) and the numbering instances that point at them: one for all bullets, one for the headings and
//! one for every numbered list. Each numbered list says where it starts with a start override, one that starts at 1 as
//! well: Word goes on counting from the list before it across instances that share a definition.

use std::fmt::Write;

use crate::template::{ElementKind, Marker};

use super::look::Look;
use super::styles::numbered_levels;
use super::xml::{NAMESPACES, XML_DECLARATION};

const BULLET: u32 = 0;
const DECIMAL: u32 = 1;
const HEADINGS: u32 = 2;
/// The first abstract id of the definitions made for lists that do not start at 1.
const FIRST_CUSTOM: u32 = 10;

/// The indent of a list level in twips: the text, and how far the marker hangs to its left.
pub(crate) fn level_indent(level: usize) -> (i64, i64) {
    (720 * (level as i64 + 1), 360)
}

pub(crate) struct Numbering {
    bullets: [&'static str; 3],
    decimal_formats: [&'static str; 3],
    headings: Option<[bool; 3]>,
    /// (level, start) of every numbered list, in order: instance number n + 3.
    instances: Vec<(usize, u64)>,
}

impl Numbering {
    pub fn new(look: &Look) -> Numbering {
        let bullets = match look.element(ElementKind::BulletList).and_then(|e| e.marker) {
            Some(Marker::Circle) => ["\u{25E6}", "\u{25AA}", "\u{2022}"],
            Some(Marker::Square) => ["\u{25AA}", "\u{2022}", "\u{25E6}"],
            Some(Marker::Dash) => ["\u{2013}", "\u{2013}", "\u{2013}"],
            _ => ["\u{2022}", "\u{25E6}", "\u{25AA}"],
        };
        let decimal_formats = match look.element(ElementKind::NumberedList).and_then(|e| e.marker) {
            Some(Marker::LowerAlpha) => ["lowerLetter", "lowerRoman", "decimal"],
            Some(Marker::LowerRoman) => ["lowerRoman", "lowerLetter", "decimal"],
            _ => ["decimal", "lowerLetter", "lowerRoman"],
        };
        let levels = numbered_levels(look);
        Numbering { bullets, decimal_formats, headings: levels.iter().any(|&b| b).then_some(levels), instances: Vec::new() }
    }

    /// The `numId` of every bullet list.
    pub fn bullet_id(&self) -> u32 {
        1
    }

    /// The `numId` of the headings' numbering, when the template numbers them.
    pub fn heading_id(&self) -> Option<u32> {
        self.headings.map(|_| 2)
    }

    /// A new instance of the decimal definition for a list at `level` that starts at `start`.
    pub fn numbered(&mut self, level: usize, start: u64) -> u32 {
        self.instances.push((level, start));
        self.instances.len() as u32 + 2
    }

    pub fn xml(&self) -> String {
        let mut x = String::from(XML_DECLARATION);
        let _ = write!(x, "<w:numbering {NAMESPACES}>");
        self.abstract_list(&mut x, BULLET, |level| {
            let (left, hanging) = level_indent(level);
            let mark = self.bullets[level % 3];
            lvl(level, "bullet", mark, left, hanging, None)
        });
        self.abstract_list(&mut x, DECIMAL, |level| {
            let (left, hanging) = level_indent(level);
            lvl(level, self.decimal_formats[level % 3], &format!("%{}.", level + 1), left, hanging, None)
        });
        if let Some(levels) = self.headings {
            self.abstract_list(&mut x, HEADINGS, |level| {
                if level > 2 || !levels[level] {
                    return lvl(level, "none", "", 0, 0, None);
                }
                // `1.` for a lone numbered level, `1.1` when the levels above are numbered too.
                let shown: Vec<usize> = (0..=level).filter(|l| levels[*l]).collect();
                let text = if shown.len() == 1 {
                    format!("%{}.", level + 1)
                } else {
                    shown.iter().map(|l| format!("%{}", l + 1)).collect::<Vec<_>>().join(".")
                };
                lvl(level, "decimal", &text, 0, 0, Some(format!("Heading{}", level + 1)))
            });
        }
        // A list that starts elsewhere than at 1 has a definition of its own that says so at its level (readers that
        // ignore a start override still get it right), and the instance carries the override as well.
        for (n, (level, start)) in self.instances.iter().enumerate().filter(|(_, (_, start))| *start != 1) {
            self.abstract_list(&mut x, FIRST_CUSTOM + n as u32, |l| {
                let (left, hanging) = level_indent(l);
                let start_at = if l == *level { *start } else { 1 };
                lvl(l, self.decimal_formats[l % 3], &format!("%{}.", l + 1), left, hanging, None).replacen("<w:start w:val=\"1\"/>", &format!("<w:start w:val=\"{start_at}\"/>"), 1)
            });
        }
        let _ = write!(x, "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"{BULLET}\"/></w:num>");
        if self.headings.is_some() {
            let _ = write!(x, "<w:num w:numId=\"2\"><w:abstractNumId w:val=\"{HEADINGS}\"/></w:num>");
        } else {
            // The id is kept so the lists' ids do not depend on the template.
            let _ = write!(x, "<w:num w:numId=\"2\"><w:abstractNumId w:val=\"{DECIMAL}\"/></w:num>");
        }
        for (n, (level, start)) in self.instances.iter().enumerate() {
            let abstract_id = if *start == 1 { DECIMAL } else { FIRST_CUSTOM + n as u32 };
            let _ = write!(
                x,
                "<w:num w:numId=\"{}\"><w:abstractNumId w:val=\"{abstract_id}\"/><w:lvlOverride w:ilvl=\"{level}\"><w:startOverride w:val=\"{start}\"/></w:lvlOverride></w:num>",
                n + 3
            );
        }
        x.push_str("</w:numbering>");
        x
    }

    fn abstract_list(&self, x: &mut String, id: u32, level: impl Fn(usize) -> String) {
        let _ = write!(x, "<w:abstractNum w:abstractNumId=\"{id}\"><w:multiLevelType w:val=\"{}\"/>", if id == HEADINGS { "multilevel" } else { "hybridMultilevel" });
        for l in 0..6 {
            x.push_str(&level(l));
        }
        x.push_str("</w:abstractNum>");
    }
}

/// One level of an abstract definition.
fn lvl(level: usize, format: &str, text: &str, left: i64, hanging: i64, style: Option<String>) -> String {
    let mut x = format!("<w:lvl w:ilvl=\"{level}\"><w:start w:val=\"1\"/><w:numFmt w:val=\"{format}\"/>");
    if let Some(s) = style {
        let _ = write!(x, "<w:pStyle w:val=\"{s}\"/><w:suff w:val=\"space\"/>");
    }
    let _ = write!(x, "<w:lvlText w:val=\"{}\"/><w:lvlJc w:val=\"left\"/>", super::xml::escape(text));
    if format != "none" && left > 0 {
        let _ = write!(x, "<w:pPr><w:ind w:left=\"{left}\" w:hanging=\"{hanging}\"/></w:pPr>");
    }
    x.push_str("</w:lvl>");
    x
}
