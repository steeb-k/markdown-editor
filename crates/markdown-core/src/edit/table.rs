//! Table helpers: insert, add/delete rows and columns, alignment, cell navigation, realign.
//!
//! The parser's cell ranges are the truth about where cells are (an escaped pipe `\|` stays
//! inside its cell; GFM also splits cells at pipes in code spans unless they are escaped, so
//! the parser's ranges decide). Every command rebuilds the whole table text from a [`Model`]
//! (columns padded to their widest cell in display columns) and replaces it with one edit;
//! [`Ctx::finish`] then shrinks the edit to what changed.

use unicode_width::UnicodeWidthStr;

use super::*;
use crate::analysis::ITable;

const MIN_WIDTH: usize = 3;
const MAX_ROWS: u32 = 1000;
const MAX_COLUMNS: u32 = 100;

#[derive(Debug, Clone)]
struct Cell {
    /// Raw range (blanks included), absolute in the old text.
    raw: (usize, usize),
    /// Trimmed content, absolute in the old text.
    content: (usize, usize),
    text: String,
    /// The parser reported this cell (as opposed to one added to fill a short row).
    real: bool,
}

impl Cell {
    fn empty() -> Self {
        Cell { raw: (0, 0), content: (0, 0), text: String::new(), real: false }
    }
}

#[derive(Debug, Clone)]
struct Row {
    /// Container prefix of the line (`> `, indentation, ...).
    prefix: String,
    /// Old line, if the row exists in the old text.
    line: Option<usize>,
    /// Start of the row after its prefix (absolute, old text).
    start: usize,
    cells: Vec<Cell>,
    /// Text of cells beyond the header's column count, which the parser ignores; kept so
    /// that re-aligning never deletes text.
    overflow: Option<String>,
    /// Line terminator after this row (unused for the last row of the table).
    eol: String,
}

#[derive(Debug)]
struct Model {
    /// Header first, then body rows.
    rows: Vec<Row>,
    aligns: Vec<ColumnAlignment>,
    delim_prefix: String,
    delim_line: usize,
    delim_start: usize,
    /// Old text covered by the table: `hull.0..hull.1`.
    hull: (usize, usize),
}

fn trim_blanks(t: &str) -> (usize, usize) {
    let lead = t.len() - t.trim_start_matches([' ', '\t']).len();
    let body = t.trim_start_matches([' ', '\t']).trim_end_matches([' ', '\t']);
    (lead, lead + body.len())
}

impl Model {
    fn new(cx: &Ctx, t: &ITable) -> Option<Model> {
        let ncols = t.alignments.len();
        let (ds, _de) = t.delimiter?;
        if ncols == 0 || t.rows.is_empty() {
            return None;
        }
        let delim_line = cx.line_of(ds);
        let mut rows = Vec::new();
        let mut last_line = delim_line;
        for r in &t.rows {
            let line = cx.line_of(r.start);
            let (ls, le) = (cx.line_start(line), cx.line_end(line));
            if r.start < ls || r.start > le {
                return None;
            }
            let mut cells: Vec<Cell> = Vec::new();
            for &(cs, ce) in r.cells.iter().take(ncols) {
                let ce = ce.min(le);
                let cs = cs.min(ce);
                let raw = &cx.text[cs..ce];
                let (a, b) = trim_blanks(raw);
                cells.push(Cell { raw: (cs, ce), content: (cs + a, cs + b), text: raw[a..b].to_owned(), real: true });
            }
            let overflow = if r.cells.len() >= ncols {
                let le_cell = cells.last().map_or(r.start, |c| c.raw.1);
                let tail = cx.text[le_cell..le].trim();
                let tail = tail.strip_prefix('|').unwrap_or(tail).trim();
                let tail = tail.strip_suffix('|').unwrap_or(tail).trim();
                (!tail.is_empty()).then(|| tail.to_owned())
            } else {
                None
            };
            while cells.len() < ncols {
                let mut c = Cell::empty();
                c.raw = (le, le);
                c.content = (le, le);
                cells.push(c);
            }
            last_line = last_line.max(line);
            rows.push(Row {
                prefix: cx.text[ls..r.start].to_owned(),
                line: Some(line),
                start: r.start,
                cells,
                overflow,
                eol: cx.text[le..cx.next_start(line)].to_owned(),
            });
        }
        let first = &rows[0];
        let hull = (first.start, cx.line_end(last_line));
        if hull.0 > hull.1 {
            return None;
        }
        Some(Model {
            rows,
            aligns: t.alignments.clone(),
            delim_prefix: cx.text[cx.line_start(delim_line)..ds].to_owned(),
            delim_line,
            delim_start: ds,
            hull,
        })
    }

    fn ncols(&self) -> usize {
        self.aligns.len()
    }

    fn new_row(&self, eol: &str) -> Row {
        Row {
            prefix: self.delim_prefix.clone(),
            line: None,
            start: 0,
            cells: vec![Cell::empty(); self.ncols()],
            overflow: None,
            eol: eol.to_owned(),
        }
    }

    /// Where an old offset is.
    fn locate(&self, cx: &Ctx, p: usize) -> Loc {
        if p < self.hull.0 {
            let first_line = self.rows[0].line.map_or(0, |l| cx.line_start(l));
            return if p >= first_line { Loc::Prefix(0) } else { Loc::Outside(p) };
        }
        if p > self.hull.1 {
            return Loc::Outside(p);
        }
        let line = cx.line_of(p);
        if line == self.delim_line {
            // Column from the pipes before `p`.
            let seg = &cx.text[self.delim_start..p.max(self.delim_start)];
            let pipes = seg.bytes().filter(|&c| c == b'|').count();
            let lead = cx.text[self.delim_start..].starts_with('|') as usize;
            let col = pipes.saturating_sub(lead).min(self.ncols() - 1);
            return Loc::Delim(col);
        }
        for (r, row) in self.rows.iter().enumerate() {
            if row.line != Some(line) {
                continue;
            }
            if p < row.start {
                return Loc::Prefix(r);
            }
            for (c, cell) in row.cells.iter().enumerate() {
                if cell.real && cell.raw.0 <= p && p <= cell.raw.1 {
                    let off = p.saturating_sub(cell.content.0).min(cell.content.1 - cell.content.0);
                    return Loc::Cell(r, c, off);
                }
            }
            let first = row.cells.first().map_or(row.start, |c| c.raw.0);
            return if p < first { Loc::Prefix(r) } else { Loc::RowEnd(r) };
        }
        Loc::Outside(p)
    }

    /// Display widths per column.
    fn widths(&self) -> Vec<usize> {
        let mut w = vec![MIN_WIDTH; self.ncols()];
        for row in &self.rows {
            for (c, cell) in row.cells.iter().enumerate() {
                w[c] = w[c].max(UnicodeWidthStr::width(cell.text.as_str()));
            }
        }
        w
    }

    fn build(&self) -> Built {
        let w = self.widths();
        // Display rows: header, delimiter, body rows.
        let mut lines: Vec<DisplayRow> = Vec::new();
        for (r, row) in self.rows.iter().enumerate() {
            let mut text = String::from("|");
            let mut cells = Vec::new();
            for (c, cell) in row.cells.iter().enumerate() {
                let cw = UnicodeWidthStr::width(cell.text.as_str());
                let pad = w[c] - cw;
                let (l, rr) = match self.aligns[c] {
                    ColumnAlignment::Right => (pad, 0),
                    ColumnAlignment::Center => (pad / 2, pad - pad / 2),
                    _ => (0, pad),
                };
                text.push(' ');
                text.push_str(&" ".repeat(l));
                let a = text.len();
                text.push_str(&cell.text);
                cells.push((a, text.len()));
                text.push_str(&" ".repeat(rr));
                text.push_str(" |");
            }
            if let Some(o) = &row.overflow {
                text.push(' ');
                text.push_str(o);
                text.push_str(" |");
            }
            lines.push((&row.prefix, text, cells, &row.eol));
            if r == 0 {
                let mut d = String::from("|");
                for (c, &cw) in w.iter().enumerate() {
                    let dashes = match self.aligns[c] {
                        ColumnAlignment::None => "-".repeat(cw),
                        ColumnAlignment::Left => format!(":{}", "-".repeat(cw - 1)),
                        ColumnAlignment::Right => format!("{}:", "-".repeat(cw - 1)),
                        ColumnAlignment::Center => format!(":{}:", "-".repeat(cw - 2)),
                    };
                    d.push(' ');
                    d.push_str(&dashes);
                    d.push_str(" |");
                }
                // The delimiter row's own terminator is the header's.
                lines.push((&self.delim_prefix, d, Vec::new(), &row.eol));
            }
        }
        // The header's terminator sits before the delimiter row; rows after it use their own.
        let mut text = String::new();
        let mut row_start = Vec::new();
        let mut cells = Vec::new();
        let n = lines.len();
        for (i, (prefix, t, cs, eol)) in lines.into_iter().enumerate() {
            if i > 0 {
                text.push_str(prefix);
            }
            let base = text.len();
            row_start.push(base);
            cells.push(cs.into_iter().map(|(a, b)| (base + a, base + b)).collect::<Vec<_>>());
            text.push_str(&t);
            if i + 1 < n {
                text.push_str(eol);
            }
        }
        // Row ends (relative), for positions after the last cell.
        Built { text, cells, row_start }
    }
}

/// Prefix, text, content ranges within the text, terminator.
type DisplayRow<'a> = (&'a str, String, Vec<(usize, usize)>, &'a str);

struct Built {
    text: String,
    /// Content ranges per display row (0 header, 1 delimiter, 2.. body), relative to the hull.
    cells: Vec<Vec<(usize, usize)>>,
    row_start: Vec<usize>,
}

impl Built {
    fn disp(r: usize) -> usize {
        if r == 0 { 0 } else { r + 1 }
    }

    fn cell(&self, r: usize, c: usize) -> (usize, usize) {
        let row = &self.cells[Self::disp(r)];
        row[c.min(row.len().saturating_sub(1))]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Loc {
    /// Before or after the table (old absolute offset).
    Outside(usize),
    /// In the container prefix or before the first cell of row `r`.
    Prefix(usize),
    /// Row, column, offset into the content.
    Cell(usize, usize, usize),
    /// After the last cell of row `r`.
    RowEnd(usize),
    /// On the delimiter row, near column `c`.
    Delim(usize),
}

fn table_index_at(cx: &Ctx, p: usize) -> Option<usize> {
    cx.a.tables.iter().position(|t| {
        let last = t.rows.last().map_or(t.end, |r| r.end).max(t.end);
        cx.line_start(cx.line_of(t.start)) <= p && p <= cx.line_end(cx.line_of(last.min(cx.b.len())))
    })
}

pub(crate) fn table_at(doc: &Document, offset: u32) -> Option<TableInfo> {
    let cx = Ctx::new(doc);
    let p = doc.byte_snapped(offset, false);
    let ti = table_index_at(&cx, p)?;
    let m = Model::new(&cx, &cx.a.tables[ti])?;
    let loc = m.locate(&cx, p);
    let (row, column) = match loc {
        Loc::Cell(r, c, _) => (Some(r as u32), Some(c as u32)),
        Loc::Prefix(r) | Loc::RowEnd(r) => (Some(r as u32), None),
        Loc::Delim(_) | Loc::Outside(_) => (None, None),
    };
    Some(TableInfo {
        range: TextRange::new(doc.unit_of(m.hull.0), doc.unit_of(m.hull.1)),
        rows: m.rows.len() as u32,
        columns: m.ncols() as u32,
        row,
        column,
        alignments: m.aligns.clone(),
    })
}

enum Target {
    /// Keep the selection where it was (mapped through the re-alignment).
    Keep(Loc, Loc),
    /// Caret at the start of a cell's content.
    Caret(usize, usize),
    /// The content of a cell.
    Select(usize, usize),
}

fn commit(cx: &Ctx, m: &Model, target: Target, noop_is_none: bool) -> Option<TextEdit> {
    let built = m.build();
    let old = &cx.text[m.hull.0..m.hull.1];
    if noop_is_none && built.text == old {
        return None;
    }
    let hs = m.hull.0;
    let delta = built.text.len() as isize - old.len() as isize;
    let map = |loc: Loc| -> usize {
        match loc {
            Loc::Outside(p) => {
                if p < hs {
                    p
                } else {
                    (p as isize + delta) as usize
                }
            }
            Loc::Prefix(r) => hs + built.row_start[Built::disp(r)],
            Loc::Delim(_) => hs + built.row_start[1],
            Loc::RowEnd(r) => {
                let d = Built::disp(r);
                let end = built.row_start.get(d + 1).map_or(built.text.len(), |&n| n);
                // Back over the next row's prefix and the terminator: the row's own end.
                let line_end = built.text[built.row_start[d]..end].find(['\n', '\r']).map_or(end, |i| built.row_start[d] + i);
                hs + line_end
            }
            Loc::Cell(r, c, off) => {
                let (a, b) = built.cell(r, c);
                hs + (a + off).min(b)
            }
        }
    };
    let sel = match target {
        Target::Keep(a, b) => (map(a), map(b)),
        Target::Caret(r, c) => {
            let (a, _) = built.cell(r, c);
            (hs + a, hs + a)
        }
        Target::Select(r, c) => {
            let (a, b) = built.cell(r, c);
            (hs + a, hs + b)
        }
    };
    Some(cx.finish(vec![Splice::replace(hs, m.hull.1 - hs, built.text)], sel))
}

pub(crate) fn table_command(doc: &Document, cmd: TableCommand, selection: TextRange) -> Option<TextEdit> {
    let cx = Ctx::new(doc);
    let (s, e) = cx.sel(selection);
    if let TableCommand::Insert { rows, columns } = cmd {
        return insert(&cx, rows, columns, s);
    }
    let ti = table_index_at(&cx, s)?;
    let mut m = Model::new(&cx, &cx.a.tables[ti])?;
    let ncols = m.ncols();
    let ls = m.locate(&cx, s);
    let le = m.locate(&cx, e);
    // Current row (None on the delimiter row) and column.
    let row = match ls {
        Loc::Cell(r, ..) | Loc::Prefix(r) | Loc::RowEnd(r) => Some(r),
        _ => None,
    };
    let col = match ls {
        Loc::Cell(_, c, _) => c,
        Loc::Delim(c) => c,
        Loc::RowEnd(_) => ncols - 1,
        _ => 0,
    }
    .min(ncols - 1);
    let eol_for = |m: &Model, r: usize| -> String {
        match m.rows.get(r) {
            Some(x) if !x.eol.is_empty() => x.eol.clone(),
            Some(x) => x.line.map_or("\n", |l| cx.eol_near(l)).to_owned(),
            None => "\n".to_owned(),
        }
    };
    match cmd {
        TableCommand::Insert { .. } => None,
        TableCommand::Realign => commit(&cx, &m, Target::Keep(ls, le), true),
        TableCommand::SetAlignment(a) => {
            m.aligns[col] = a;
            commit(&cx, &m, Target::Keep(ls, le), false)
        }
        TableCommand::AddRowAbove => {
            let r = row.filter(|&r| r >= 1)?;
            let eol = eol_for(&m, r);
            let nr = m.new_row(&eol);
            m.rows.insert(r, nr);
            commit(&cx, &m, Target::Caret(r, col), false)
        }
        TableCommand::AddRowBelow => {
            let r = row.map_or(0, |r| r) + 1;
            append_row(&cx, &mut m, r, &eol_for);
            commit(&cx, &m, Target::Caret(r, col), false)
        }
        TableCommand::DeleteRow => {
            let r = row.filter(|&r| r >= 1)?;
            m.rows.remove(r);
            let nr = r.min(m.rows.len() - 1);
            commit(&cx, &m, Target::Caret(nr, col), false)
        }
        TableCommand::AddColumnLeft | TableCommand::AddColumnRight => {
            let at = if cmd == TableCommand::AddColumnLeft { col } else { col + 1 };
            for r in &mut m.rows {
                r.cells.insert(at, Cell::empty());
            }
            m.aligns.insert(at, ColumnAlignment::None);
            commit(&cx, &m, Target::Caret(row.unwrap_or(0), at), false)
        }
        TableCommand::DeleteColumn => {
            if ncols <= 1 {
                return None;
            }
            for r in &mut m.rows {
                r.cells.remove(col);
            }
            m.aligns.remove(col);
            commit(&cx, &m, Target::Caret(row.unwrap_or(0), col.min(ncols - 2)), false)
        }
        TableCommand::NextCell => {
            let (r, c) = match row {
                None => (1, 0),
                Some(r) if col + 1 < ncols => (r, col + 1),
                Some(r) => (r + 1, 0),
            };
            if r >= m.rows.len() {
                append_row(&cx, &mut m, r, &eol_for);
            }
            commit(&cx, &m, Target::Select(r, c), false)
        }
        TableCommand::PreviousCell => {
            let (r, c) = match row {
                None => (0, ncols - 1),
                Some(r) if col > 0 => (r, col - 1),
                Some(0) => return None,
                Some(r) => (r - 1, ncols - 1),
            };
            commit(&cx, &m, Target::Select(r, c), false)
        }
    }
}

/// Insert an empty body row so it becomes row `r` (appending after the last row if need be).
fn append_row(cx: &Ctx, m: &mut Model, r: usize, eol_for: &dyn Fn(&Model, usize) -> String) {
    let _ = cx;
    let r = r.min(m.rows.len());
    if r == m.rows.len() {
        // After the last row: it needs a terminator now, the new last row needs none.
        let last = m.rows.len() - 1;
        let eol = eol_for(m, last);
        m.rows[last].eol = eol.clone();
        let nr = m.new_row("");
        m.rows.push(nr);
    } else {
        let eol = m.rows[r - 1].eol.clone();
        let nr = m.new_row(&eol);
        m.rows.insert(r, nr);
    }
}

fn insert(cx: &Ctx, rows: u32, columns: u32, p: usize) -> Option<TextEdit> {
    let rows = rows.min(MAX_ROWS) as usize;
    let cols = columns.clamp(1, MAX_COLUMNS) as usize;
    let line = cx.line_of(p);
    let info = cx.info(line);
    let eol = cx.eol_near(line);
    let in_table = table_index_at(cx, p);

    // The table (every line prefixed with the caret line's block quote markers).
    let quote = cx.text[info.start..info.qp_end].to_owned();
    let blank = quote.trim_end().to_owned();
    let m = Model {
        rows: (0..=rows)
            .map(|_| Row {
                prefix: quote.clone(),
                line: None,
                start: 0,
                cells: vec![Cell::empty(); cols],
                overflow: None,
                eol: eol.to_owned(),
            })
            .collect(),
        aligns: vec![ColumnAlignment::None; cols],
        delim_prefix: quote.clone(),
        delim_line: 0,
        delim_start: 0,
        hull: (0, 0),
    };
    let built = m.build();
    let chunk = format!("{quote}{}", built.text);
    let chunk_caret = quote.len() + built.cell(0, 0).0;
    let prev_text = line > 0 && !cx.info(line - 1).blank;

    let (at, remove, out, caret) = if let Some(ti) = in_table {
        // Inside a table: after it, with a blank line between.
        let t = &cx.a.tables[ti];
        let last = cx.line_of(t.rows.last().map_or(t.end, |r| r.end).max(t.end).min(cx.b.len()));
        let at = cx.line_end(last);
        let sep_after = last + 1 < cx.line_count() && !cx.info(last + 1).blank;
        let mut out = format!("{eol}{blank}{eol}");
        let caret = out.len() + chunk_caret;
        out.push_str(&chunk);
        if sep_after {
            out.push_str(eol);
            out.push_str(&blank);
        }
        (at, 0, out, caret)
    } else if info.blank {
        // On a blank line: the table replaces it, blank lines kept around it as needed.
        let sep_after = line + 1 < cx.line_count() && !cx.info(line + 1).blank;
        let mut out = String::new();
        if prev_text {
            out.push_str(&blank);
            out.push_str(eol);
        }
        let caret = out.len() + chunk_caret;
        out.push_str(&chunk);
        if sep_after {
            out.push_str(eol);
            out.push_str(&blank);
        }
        (info.start, info.end - info.start, out, caret)
    } else if p <= info.ind_end {
        // At the start of a text line: before it.
        let mut out = String::new();
        if prev_text {
            out.push_str(&blank);
            out.push_str(eol);
        }
        let caret = out.len() + chunk_caret;
        out.push_str(&chunk);
        out.push_str(eol);
        out.push_str(&blank);
        out.push_str(eol);
        (info.start, 0, out, caret)
    } else {
        // Elsewhere in a text line: after it.
        let sep_after = line + 1 < cx.line_count() && !cx.info(line + 1).blank;
        let mut out = format!("{eol}{blank}{eol}");
        let caret = out.len() + chunk_caret;
        out.push_str(&chunk);
        if sep_after {
            out.push_str(eol);
            out.push_str(&blank);
        }
        (info.end, 0, out, caret)
    };
    let caret_abs = at + caret;
    Some(cx.finish(vec![Splice::replace(at, remove, out)], (caret_abs, caret_abs)))
}
