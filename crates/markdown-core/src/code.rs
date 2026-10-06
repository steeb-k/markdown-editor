//! Fenced code in the editor: which runs of a block are which role, which language a block has and
//! how to change it. The highlighting itself, and the cache, are in [`crate::highlight`].

use std::time::{Duration, Instant};

use crate::document::Document;
use crate::highlight;
use crate::render::HIGHLIGHT_FLOOR_BYTES;
use crate::types::*;

/// Code highlighted per query, in the units of [`highlight::cost`], not counting what the cache
/// already holds. The preview's budget is 128 KB because it renders everything after every edit;
/// a query here asks for a window, off the main thread, and a 2 000-line block of Rust costs some
/// 140 KB. Past it the remaining blocks are plain.
const BUDGET_BYTES: usize = 512 * 1024;
/// And in time, for the code that highlights ten times slower than usual: a block that is not done
/// when it runs out is plain (never partly coloured), and is tried again by the next query.
const BUDGET_TIME: Duration = Duration::from_millis(400);

/// A fenced block's code as the highlighter sees it: the lines without their container prefix and
/// line terminator's `\r`, and where each came from.
struct CodeText {
    text: String,
    /// `(offset in text, offset in the document, length)` of each line's content, without its `\n`.
    parts: Vec<(usize, usize, usize)>,
}

impl Document {
    fn code_text(&self, c: &crate::analysis::ICode) -> CodeText {
        let src = self.text();
        let mut text = String::new();
        let mut parts = Vec::with_capacity(c.chunks.len());
        // A chunk is one line, or several when nothing separates them (no container prefix).
        // A line ends at `\n`, `\r\n` or a lone `\r` (the core reads all three as line ends): a run never
        // crosses one, whatever the highlighter makes of the text.
        for &(s, e) in &c.chunks {
            let seg = &src.as_bytes()[s..e];
            let mut i = 0;
            while i < seg.len() {
                let from = i;
                while i < seg.len() && seg[i] != b'\n' && seg[i] != b'\r' {
                    i += 1;
                }
                let content_end = i;
                let terminated = i < seg.len();
                if terminated {
                    i += if seg[i] == b'\r' && seg.get(i + 1) == Some(&b'\n') { 2 } else { 1 };
                }
                parts.push((text.len(), s + from, content_end - from));
                text.push_str(&src[s + from..s + content_end]);
                if terminated {
                    text.push('\n');
                }
            }
        }
        CodeText { text, parts }
    }

    /// The info string of a fenced block.
    fn code_info(&self, c: &crate::analysis::ICode) -> &str {
        &self.text()[c.info.0..c.info.1]
    }

    /// The fenced blocks meeting the byte window (all for `None`; an empty window selects the one
    /// containing it), in order.
    fn codes_in(&self, w: Option<(usize, usize)>) -> &[crate::analysis::ICode] {
        let codes = &self.analysis().codes;
        let Some((ws, we)) = w else { return codes };
        let lo = codes.partition_point(|c| c.end < ws || (c.end == ws && ws != we));
        let hi = codes.partition_point(|c| c.start < we.max(ws + 1));
        &codes[lo.min(hi)..hi]
    }

    /// The colour roles of the code in the fenced blocks that meet `within` (all for `None`),
    /// clipped to `within`: sorted, disjoint, each inside one line of one block, and covering
    /// code text only (never a fence or the container's `>`). Blocks are highlighted
    /// independently and answered from a cache keyed on their language and code, so the blocks an
    /// edit did not touch cost nothing; a block in an unknown language, over the preview's limits
    /// (200 000 bytes, a line over 1 000) or past this query's budget (see `BUDGET_BYTES`) is
    /// plain, never partly coloured. Indented code has no language.
    pub fn code_highlights(&self, within: Option<TextRange>) -> Vec<CodeHighlight> {
        let w = self.within_bytes(within);
        let mut pairs: Vec<(usize, usize)> = Vec::new();
        let mut roles: Vec<CodeRole> = Vec::new();
        let mut spent = 0usize;
        let mut deadline: Option<Instant> = None;
        for c in self.codes_in(w) {
            let info = self.code_info(c);
            if highlight::language_name(info).is_none() {
                continue;
            }
            let code = self.code_text(c);
            let runs = match highlight::roles_cached(info, &code.text) {
                Some(runs) => runs,
                None => {
                    let cost = highlight::cost(&code.text);
                    if spent + cost > BUDGET_BYTES || !highlight::is_highlightable(info, &code.text) {
                        continue;
                    }
                    let deadline = *deadline.get_or_insert_with(|| Instant::now() + BUDGET_TIME);
                    // Code wholly inside the floor is always done, whatever the clock says.
                    let capped = spent + cost > HIGHLIGHT_FLOOR_BYTES;
                    spent += cost;
                    match highlight::roles_until(info, &code.text, capped.then_some(deadline)) {
                        Some(runs) => runs,
                        None => continue,
                    }
                }
            };
            // Runs and lines are both in order: one pass.
            let mut p = 0;
            for run in runs.iter() {
                let (a, b) = (run.start as usize, run.end as usize);
                while p < code.parts.len() && code.parts[p].0 + code.parts[p].2 <= a {
                    p += 1;
                }
                let mut q = p;
                while q < code.parts.len() && code.parts[q].0 < b {
                    let (cs, src, len) = code.parts[q];
                    let (from, to) = (a.max(cs), b.min(cs + len));
                    if from < to {
                        let (mut s, mut e) = (src + from - cs, src + to - cs);
                        if let Some((ws, we)) = w {
                            s = s.max(ws);
                            e = e.min(we);
                        }
                        if s < e || w.is_some_and(|(ws, we)| ws == we && s <= ws && ws < e) {
                            pairs.push((s, e));
                            roles.push(run.role);
                        }
                    }
                    q += 1;
                }
            }
        }
        // A window of one position selects the run containing it: its span is kept whole.
        let conv = self.convert_nested(&pairs);
        conv.into_iter().zip(roles).map(|((a, b), role)| CodeHighlight { range: TextRange::new(a, b), role }).collect()
    }

    /// `range` widened to whole fenced blocks: what to restyle after an edit, since the colours
    /// of a block depend on all of it, not only on the lines the dirty range names.
    pub fn code_extent(&self, range: TextRange) -> TextRange {
        let lo = range.start.min(range.end);
        let hi = range.start.max(range.end);
        let w = self.within_bytes(Some(TextRange::new(lo, hi)));
        let blocks = self.codes_in(w);
        let (Some(first), Some(last)) = (blocks.first(), blocks.last()) else { return TextRange::new(lo, hi) };
        TextRange::new(lo.min(self.unit_of(first.start)), hi.max(self.unit_of(last.end)))
    }

    fn language_of(&self, c: &crate::analysis::ICode) -> Option<CodeLanguage> {
        let info = self.code_info(c);
        let display = highlight::language_name(info)?;
        let (a, b) = highlight::info_token(info)?;
        Some(CodeLanguage {
            name: info[a..b].to_owned(),
            display,
            info_range: TextRange::new(self.unit_of(c.info.0 + a), self.unit_of(c.info.0 + b)),
            block: TextRange::new(self.unit_of(c.start), self.unit_of(c.end)),
        })
    }

    /// The language of the fenced block containing `offset` (its fences included), when the
    /// highlighter knows it: `None` for an indented block, a fence with no language or an unknown one.
    pub fn code_language_at(&self, offset: u32) -> Option<CodeLanguage> {
        let b = self.byte_snapped(offset, false);
        let c = self.codes_in(Some((b, b))).first()?;
        (c.start <= b && b <= c.end).then(|| self.language_of(c)).flatten()
    }

    /// The languages of all fenced blocks meeting `within` (all for `None`) that have a known one,
    /// in order: what the editor draws a badge for.
    pub fn code_languages(&self, within: Option<TextRange>) -> Vec<CodeLanguage> {
        let w = self.within_bytes(within);
        self.codes_in(w).iter().filter_map(|c| self.language_of(c)).collect()
    }

    /// Makes the fenced block `block` (a [`CodeLanguage::block`] or [`Block::range`]) `token`'s
    /// language: replaces the first word of its info string, keeping what follows it
    /// (`rust,ignore` becomes `python,ignore`), or writes the word where there is none. `None`
    /// when `block` is not a fenced block or `token` is not a single word.
    pub fn set_code_language(&self, block: TextRange, token: &str) -> Option<TextEdit> {
        if token.is_empty() || highlight::info_token(token) != Some((0, token.len())) || token.contains('`') {
            return None;
        }
        let start = self.byte_snapped(block.start, false);
        let c = self.analysis().codes.iter().find(|c| c.start == start)?;
        let info = self.code_info(c);
        let (a, b) = highlight::info_token(info).unwrap_or((info.len(), info.len()));
        let (from, to) = (self.unit_of(c.info.0 + a), self.unit_of(c.info.0 + b));
        let end = from + self.units_in(token);
        Some(TextEdit { range: TextRange::new(from, to), replacement: token.to_owned(), selection: TextRange::new(end, end) })
    }
}
