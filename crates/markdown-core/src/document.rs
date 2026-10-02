use std::cmp::Reverse;

use crate::analysis::{analyze, Analysis};
use crate::dirty::dirty_range;
use crate::offsets::OffsetMap;
use crate::types::*;

/// A Markdown document: text, offset table and analysis, re-derived after every edit.
///
/// Every range crossing this API is in the document's [`OffsetEncoding`] unit.
#[derive(Debug, Clone)]
pub struct Document {
    text: String,
    encoding: OffsetEncoding,
    map: OffsetMap,
    analysis: Analysis,
    revision: u64,
}

impl Document {
    pub fn new(text: &str, encoding: OffsetEncoding) -> Self {
        Self {
            text: text.to_owned(),
            encoding,
            map: OffsetMap::new(text, encoding),
            analysis: analyze(text),
            revision: 0,
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn encoding(&self) -> OffsetEncoding {
        self.encoding
    }

    /// Length of the text in the document's offset unit.
    pub fn len(&self) -> u32 {
        self.map.len_units().min(u32::MAX as usize) as u32
    }

    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    /// Starts at 0, incremented by every `replace` and `set_text`.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Replace `range` with `with`. Returns the range of the new text that needs
    /// restyling. Never panics: bad ranges are reported as [`EditError`] and leave the
    /// document unchanged.
    pub fn replace(&mut self, range: TextRange, with: &str) -> Result<Update, EditError> {
        if range.start > range.end {
            return Err(EditError::InvertedRange);
        }
        let bs = self.unit_to_byte(range.start)?;
        let be = self.unit_to_byte(range.end)?;
        let new_len = self.text.len() - (be - bs) + with.len();
        if new_len > u32::MAX as usize {
            return Err(EditError::TooLarge);
        }
        // Build and analyze the new state before touching `self`, so that even a panic in
        // the analysis (a bug; the FFI layer reports it and keeps the object) cannot leave
        // the text and its analysis out of step.
        let mut text = String::with_capacity(new_len);
        text.push_str(&self.text[..bs]);
        text.push_str(with);
        text.push_str(&self.text[be..]);
        let new = analyze(&text);
        let map = OffsetMap::new(&text, self.encoding);
        let (ds, de) = dirty_range(&self.analysis, &new, bs, be, with.len(), text.len());
        self.text = text;
        self.analysis = new;
        self.map = map;
        self.revision += 1;
        let dirty = TextRange::new(self.to_unit(ds), self.to_unit(de));
        Ok(Update { dirty, revision: self.revision })
    }

    /// Replace the whole text. The dirty range is the whole new text.
    pub fn set_text(&mut self, text: &str) -> Update {
        let analysis = analyze(text);
        self.map = OffsetMap::new(text, self.encoding);
        self.text = text.to_owned();
        self.analysis = analysis;
        self.revision += 1;
        Update { dirty: TextRange::new(0, self.len()), revision: self.revision }
    }

    /// Spans intersecting `within` (all spans for `None`), sorted by start ascending then
    /// end descending; any two are disjoint or properly nested. An empty `within`
    /// returns the spans containing that position.
    pub fn spans(&self, within: Option<TextRange>) -> Vec<Span> {
        let idx = self.span_indices(within);
        let spans = &self.analysis.spans[idx.0..idx.1];
        let w = self.within_bytes(within);
        let picked: Vec<_> = spans.iter().filter(|s| w.is_none_or(|w| hits(s.start, s.end, w))).collect();
        let pairs: Vec<(usize, usize)> = picked.iter().map(|s| (s.start, s.end)).collect();
        let conv = self.convert_nested(&pairs);
        picked
            .iter()
            .zip(conv)
            .map(|(s, (a, b))| Span { range: TextRange::new(a, b), kind: s.kind })
            .collect()
    }

    /// `Markup` spans with the owner and scope Live mode needs to conceal them.
    pub fn markup_spans(&self, within: Option<TextRange>) -> Vec<MarkupSpan> {
        let idx = self.span_indices(within);
        let w = self.within_bytes(within);
        let picked: Vec<_> = self.analysis.spans[idx.0..idx.1]
            .iter()
            .filter(|s| s.meta.is_some() && w.is_none_or(|w| hits(s.start, s.end, w)))
            .collect();
        // Convert spans and owners in one go: spans first (nested sweep), owners via the
        // general (non-monotone) path.
        let pairs: Vec<(usize, usize)> = picked.iter().map(|s| (s.start, s.end)).collect();
        let conv = self.convert_nested(&pairs);
        let mut cur = self.map.cursor(&self.text);
        picked
            .iter()
            .zip(conv)
            .map(|(s, (a, b))| {
                let m = s.meta.unwrap();
                let os = cur.to(m.owner.0) as u32;
                let oe = cur.to(m.owner.1) as u32;
                MarkupSpan {
                    range: TextRange::new(a, b),
                    owner: TextRange::new(os, oe),
                    scope: m.scope,
                    in_table: m.in_table,
                }
            })
            .collect()
    }

    /// Leaf blocks in document order.
    pub fn blocks(&self) -> Vec<Block> {
        let pairs: Vec<(usize, usize)> = self.analysis.blocks.iter().map(|b| (b.start, b.end)).collect();
        let conv = self.convert_nested(&pairs);
        self.analysis
            .blocks
            .iter()
            .zip(conv)
            .map(|(b, (s, e))| Block {
                kind: b.kind,
                range: TextRange::new(s, e),
                line: b.line,
                heading_level: b.heading_level,
                depth: b.depth,
            })
            .collect()
    }

    /// Human-language text only, adjacent pieces merged, clipped to `within`.
    pub fn prose_ranges(&self, within: Option<TextRange>) -> Vec<TextRange> {
        let w = self.within_bytes(within);
        let prose = &self.analysis.prose;
        let (lo, hi) = match w {
            Some(w) => (
                prose.partition_point(|p| p.1 <= w.0),
                prose.partition_point(|p| p.0 < w.1.max(w.0 + 1)),
            ),
            None => (0, prose.len()),
        };
        let pairs: Vec<(usize, usize)> = prose[lo..hi]
            .iter()
            .map(|&(s, e)| match w {
                Some(w) => (s.max(w.0), e.min(w.1)),
                None => (s, e),
            })
            .filter(|&(s, e)| s < e)
            .collect();
        self.convert_nested(&pairs).into_iter().map(|(s, e)| TextRange::new(s, e)).collect()
    }

    pub fn images(&self) -> Vec<ImageRef> {
        let mut order: Vec<usize> = (0..self.analysis.images.len()).collect();
        order.sort_by_key(|&i| (self.analysis.images[i].start, Reverse(self.analysis.images[i].end)));
        let pairs: Vec<(usize, usize)> =
            order.iter().map(|&i| (self.analysis.images[i].start, self.analysis.images[i].end)).collect();
        let conv = self.convert_nested(&pairs);
        let mut out: Vec<(usize, ImageRef)> = order
            .iter()
            .zip(conv)
            .map(|(&i, (s, e))| {
                let im = &self.analysis.images[i];
                (
                    i,
                    ImageRef {
                        range: TextRange::new(s, e),
                        destination: im.destination.clone(),
                        alt: im.alt.clone(),
                        title: im.title.clone(),
                        standalone: im.standalone,
                    },
                )
            })
            .collect();
        out.sort_by_key(|(i, _)| *i);
        out.into_iter().map(|(_, r)| r).collect()
    }

    /// Live mode: which source is not drawn, which lines collapse and what is drawn instead,
    /// for `selection` (an inverted range is normalized), restricted to `within` (`None`:
    /// the whole document). A pure query over the current analysis: query again after every
    /// edit and selection change, and for newly visible text. See [`Concealment`].
    pub fn concealment(&self, selection: TextRange, within: Option<TextRange>) -> Concealment {
        crate::conceal::compute(self, selection, within)
    }

    /// What focus mode keeps at full strength for `selection`: sorted, disjoint ranges that do
    /// not touch. Empty when the caret is on a blank line or between blocks (everything is dimmed).
    /// See [`FocusScope`] and the `focus` module for what a sentence is.
    pub fn focus_range(&self, selection: TextRange, scope: FocusScope) -> Vec<TextRange> {
        crate::focus::focus_ranges(self, selection, scope, None)
    }

    /// The prose of every leaf block that intersects `within` (`None`: all of them), one unit
    /// per block, for a platform tagger. The pieces of all units are exactly
    /// [`Document::prose_ranges`] of the same text. See [`PosUnit`].
    pub fn pos_units(&self, within: Option<TextRange>) -> Vec<PosUnit> {
        crate::pos::pos_units(self, within)
    }

    /// Everything a shell wants after the selection moved, in one call: the concealment (when
    /// `conceal`), the format state, the table at the selection and the focus ranges (when
    /// `focus` is given). `within` restricts the concealment, and the units the focus ranges
    /// are computed for, to a window of the text; results elsewhere are not computed.
    pub fn selection_state(
        &self,
        selection: TextRange,
        within: Option<TextRange>,
        conceal: bool,
        focus: Option<FocusScope>,
    ) -> SelectionState {
        let lo = selection.start.min(selection.end);
        SelectionState {
            concealment: conceal.then(|| self.concealment(selection, within)),
            format_state: self.format_state(selection),
            table: self.table_at(lo),
            focus: focus.map(|scope| crate::focus::focus_ranges(self, selection, scope, within)),
        }
    }

    /// The link containing `offset` (the character at it) and its destination, for Cmd-click.
    pub fn link_at(&self, offset: u32) -> Option<LinkTarget> {
        crate::conceal::link_at(self, offset)
    }

    // ----- editing commands (implemented in `crate::edit`) --------------------------------

    /// Apply a formatting command to `selection`. `None` means nothing to do. The edit
    /// applies cleanly with [`Document::replace`]; see [`TextEdit`].
    pub fn format(&self, cmd: FormatCommand, selection: TextRange) -> Option<TextEdit> {
        crate::edit::format(self, cmd, selection)
    }

    /// Which formats are active at `selection` (for the toolbar).
    pub fn format_state(&self, selection: TextRange) -> FormatState {
        crate::edit::format_state(self, selection)
    }

    /// The Return key: list and block quote continuation. `None`: insert a plain newline.
    pub fn newline(&self, selection: TextRange) -> Option<TextEdit> {
        crate::edit::newline(self, selection)
    }

    /// Tab (`outdent == false`) and Shift-Tab. `None`: the shell does its default.
    pub fn indent(&self, selection: TextRange, outdent: bool) -> Option<TextEdit> {
        crate::edit::indent(self, selection, outdent)
    }

    /// Flip the task item whose marker contains `at`, or else the one on `at`'s line.
    pub fn toggle_task(&self, at: u32) -> Option<TextEdit> {
        crate::edit::toggle_task(self, at)
    }

    /// A table helper. `Insert` works anywhere; every other command needs the start of
    /// `selection` inside a table (`None` otherwise) and re-aligns the whole table.
    pub fn table_command(&self, cmd: TableCommand, selection: TextRange) -> Option<TextEdit> {
        crate::edit::table_command(self, cmd, selection)
    }

    /// The table containing `offset` (the end of its last line included), if any.
    pub fn table_at(&self, offset: u32) -> Option<TableInfo> {
        crate::edit::table_at(self, offset)
    }

    // ----- offset plumbing --------------------------------------------------------------

    pub(crate) fn analysis(&self) -> &Analysis {
        &self.analysis
    }

    /// Unit offset to byte offset, snapping to the code point boundary at or before it
    /// (`ceil == false`) or at or after it (`ceil == true`); clamped to the text.
    pub(crate) fn byte_snapped(&self, unit: u32, ceil: bool) -> usize {
        match self.map.locate_unit(&self.text, unit as usize) {
            None => self.text.len(),
            Some((b, true)) => b,
            Some((b, false)) => {
                if ceil {
                    b + self.text[b..].chars().next().map_or(0, char::len_utf8)
                } else {
                    b
                }
            }
        }
    }

    pub(crate) fn unit_of(&self, byte: usize) -> u32 {
        self.to_unit(byte)
    }

    /// Length of `s` in the document's offset unit.
    pub(crate) fn units_in(&self, s: &str) -> u32 {
        s.chars()
            .map(|c| match self.encoding {
                OffsetEncoding::Utf8 => c.len_utf8(),
                OffsetEncoding::Utf16 => c.len_utf16(),
                OffsetEncoding::Utf32 => 1,
            })
            .sum::<usize>() as u32
    }

    fn unit_to_byte(&self, unit: u32) -> Result<usize, EditError> {
        match self.map.locate_unit(&self.text, unit as usize) {
            None => Err(EditError::OutOfBounds),
            Some((b, true)) => Ok(b),
            Some((_, false)) => Err(EditError::NotOnCodePointBoundary),
        }
    }

    fn to_unit(&self, byte: usize) -> u32 {
        self.map.byte_to_unit(&self.text, byte) as u32
    }

    /// Query range in bytes, clamped to the text; endpoints inside a code point snap
    /// outward. `None` for "everything". An inverted range yields an empty window.
    pub(crate) fn within_bytes(&self, within: Option<TextRange>) -> Option<(usize, usize)> {
        let w = within?;
        let total = self.text.len();
        let floor = |u: u32| match self.map.locate_unit(&self.text, u as usize) {
            Some((b, _)) => b,
            None => total,
        };
        let ceil = |u: u32| match self.map.locate_unit(&self.text, u as usize) {
            Some((b, true)) => b,
            Some((b, false)) => b + self.text[b..].chars().next().map_or(0, char::len_utf8),
            None => total,
        };
        if w.start > w.end {
            return Some((0, 0));
        }
        Some((floor(w.start), ceil(w.end)))
    }

    /// Candidate index window in `analysis.spans` for a byte window.
    fn span_indices(&self, within: Option<TextRange>) -> (usize, usize) {
        self.span_indices_bytes(self.within_bytes(within))
    }

    /// The same for a window already in bytes.
    pub(crate) fn span_indices_bytes(&self, window: Option<(usize, usize)>) -> (usize, usize) {
        let a = &self.analysis;
        match window {
            None => (0, a.spans.len()),
            Some((ws, we)) => {
                let lo = a.prefix_max_end.partition_point(|&m| m <= ws);
                let hi = a.spans.partition_point(|s| s.start < we.max(ws + 1));
                (lo.min(hi), hi)
            }
        }
    }

    /// Convert byte ranges that are sorted by (start asc, end desc) and properly nested
    /// (or disjoint) in a single forward sweep of the text.
    pub(crate) fn convert_nested(&self, items: &[(usize, usize)]) -> Vec<(u32, u32)> {
        let mut cur = self.map.cursor(&self.text);
        let mut out = vec![(0u32, 0u32); items.len()];
        let mut stack: Vec<(usize, usize)> = Vec::new(); // (end byte, index)
        for (i, &(s, e)) in items.iter().enumerate() {
            while let Some(&(end, idx)) = stack.last() {
                if end <= s {
                    out[idx].1 = cur.to(end) as u32;
                    stack.pop();
                } else {
                    break;
                }
            }
            out[i].0 = cur.to(s) as u32;
            stack.push((e, i));
        }
        while let Some((end, idx)) = stack.pop() {
            out[idx].1 = cur.to(end) as u32;
        }
        out
    }
}

/// Span `[s, e)` intersects window `w`; an empty window selects spans containing it.
fn hits(s: usize, e: usize, w: (usize, usize)) -> bool {
    if w.0 == w.1 {
        s <= w.0 && w.0 < e
    } else {
        s < w.1 && e > w.0
    }
}
