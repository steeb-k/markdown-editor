//! Authorship: which author each character of a document belongs to, how text edits move
//! that attribution, and (in [`file`]) how it is stored on disk in the open
//! [Markdown Annotations](https://github.com/iainc/Markdown-Annotations) format.
//!
//! This is pure range arithmetic over a document's offset unit. It never parses Markdown and
//! never owns the text, so it is cheap enough to live on a shell's main thread next to the
//! text view (where undo has to be synchronous) while the parsing `Document` lives elsewhere.
//!
//! Every character is either unattributed or belongs to exactly one author. Runs are sorted,
//! disjoint, non-empty and merged when adjacent with the same author. Author 0 is always
//! "Me": the Human author whose name the shell supplies.

mod diff;
mod file;

pub use file::{
    split_annotations, AnnotationStatus, GraphemeRange, LineEnding, ParsedAnnotations,
    ParsedAuthor, SplitFile,
};

use crate::types::{OffsetEncoding, TextRange};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AuthorKind {
    /// `@` in the file.
    Human,
    /// `&` in the file.
    Ai,
    /// `*` in the file: reference material, someone else's text.
    Reference,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Author {
    pub kind: AuthorKind,
    pub name: String,
}

impl Author {
    pub fn new(kind: AuthorKind, name: impl Into<String>) -> Self {
        Self { kind, name: name.into() }
    }
}

/// How inserted text is attributed by [`Authorship::edit`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attribution {
    /// Typed or plainly pasted by this author (normally Me).
    Typed(Author),
    /// Paste As: attributed to this author.
    As(Author),
    /// Programmatic edits: the text takes the attribution of the character before it
    /// (see [`Authorship::edit`]).
    Inherit,
    /// Leave the inserted text unattributed.
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthorRun {
    pub range: TextRange,
    /// Index into [`Authorship::authors`].
    pub author_index: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Run {
    pub start: u32,
    pub end: u32,
    pub author: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AuthorEntry {
    pub author: Author,
    /// Came from a file: written back even if it has no text any more.
    pub from_file: bool,
}

/// What `file_tail` needs to give an untouched file back byte for byte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Origin {
    pub body: String,
    pub tail: String,
    pub canonical: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Authorship {
    pub(crate) encoding: OffsetEncoding,
    /// Index 0 is Me.
    pub(crate) authors: Vec<AuthorEntry>,
    /// Author indexes in the order they are written to a file.
    pub(crate) order: Vec<u32>,
    pub(crate) runs: Vec<Run>,
    pub(crate) hash_key: String,
    /// Annotation lines this app does not understand, kept verbatim for the next save.
    pub(crate) unknown: Vec<String>,
    pub(crate) origin: Option<Origin>,
}

/// A cheap copy of the attribution state, for undo. It carries runs and authors only.
#[derive(Debug, Clone)]
pub struct AuthorshipSnapshot(Authorship);

impl PartialEq for AuthorshipSnapshot {
    fn eq(&self, other: &Self) -> bool {
        self.0.same_state(&other.0)
    }
}

impl Authorship {
    /// An empty attribution; Me is called "Me" until [`Authorship::set_me_name`].
    pub fn new(encoding: OffsetEncoding) -> Self {
        Self::with_me(encoding, "Me")
    }

    pub fn with_me(encoding: OffsetEncoding, me: &str) -> Self {
        Self {
            encoding,
            authors: vec![AuthorEntry { author: Author::new(AuthorKind::Human, me), from_file: false }],
            order: vec![0],
            runs: Vec::new(),
            hash_key: "Annotations".to_string(),
            unknown: Vec::new(),
            origin: None,
        }
    }

    pub fn encoding(&self) -> OffsetEncoding {
        self.encoding
    }

    pub fn me(&self) -> &Author {
        &self.authors[0].author
    }

    /// Renames Me. If another human of that name is already known, their text becomes Me's.
    pub fn set_me_name(&mut self, name: &str) {
        if self.authors[0].author.name == name {
            return;
        }
        let other = (1..self.authors.len()).find(|&i| {
            self.authors[i].author.kind == AuthorKind::Human && self.authors[i].author.name == name
        });
        self.authors[0].author.name = name.to_string();
        if let Some(i) = other {
            self.merge_author_into_me(i as u32);
        }
    }

    fn merge_author_into_me(&mut self, i: u32) {
        for r in &mut self.runs {
            if r.author == i {
                r.author = 0;
            }
        }
        self.merge();
        self.order.retain(|&o| o != i);
        // Keep indexes dense: move the last author into slot `i`.
        let last = self.authors.len() as u32 - 1;
        self.authors.swap_remove(i as usize);
        if i != last {
            for r in &mut self.runs {
                if r.author == last {
                    r.author = i;
                }
            }
            for o in &mut self.order {
                if *o == last {
                    *o = i;
                }
            }
        }
    }

    /// All authors, Me first. `AuthorRun::author_index` indexes this.
    pub fn authors(&self) -> Vec<Author> {
        self.authors.iter().map(|a| a.author.clone()).collect()
    }

    /// True if some text is attributed to someone other than Me: only then does a file get
    /// an annotation block.
    pub fn has_marks(&self) -> bool {
        self.runs.iter().any(|r| r.author != 0)
    }

    /// The attributed runs inside `within` (all of them when `None`), clipped to it.
    pub fn runs(&self, within: Option<TextRange>) -> Vec<AuthorRun> {
        let (lo, hi) = match within {
            Some(w) => (w.start, w.end),
            None => (0, u32::MAX),
        };
        let first = self.runs.partition_point(|r| r.end <= lo);
        self.runs[first..]
            .iter()
            .take_while(|r| r.start < hi)
            .map(|r| AuthorRun {
                range: TextRange::new(r.start.max(lo), r.end.min(hi)),
                author_index: r.author,
            })
            .filter(|r| !r.range.is_empty())
            .collect()
    }

    /// The author of the character at `pos`, if attributed.
    pub fn author_at(&self, pos: u32) -> Option<u32> {
        let i = self.runs.partition_point(|r| r.end <= pos);
        self.runs.get(i).filter(|r| r.start <= pos).map(|r| r.author)
    }

    /// `Some(index)` if every character of `range` belongs to that author (unattributed
    /// text counts as Me, so a mix of the two is "Me"); `None` for a mixture or an empty range.
    pub fn uniform_author(&self, range: TextRange) -> Option<u32> {
        if range.is_empty() {
            return None;
        }
        let mut found: Option<u32> = None;
        let mut pos = range.start;
        let see = |a: u32, found: &mut Option<u32>| match *found {
            None => {
                *found = Some(a);
                true
            }
            Some(f) => f == a,
        };
        for r in self.runs(Some(range)) {
            if r.range.start > pos && !see(0, &mut found) {
                return None;
            }
            if !see(r.author_index, &mut found) {
                return None;
            }
            pos = r.range.end;
        }
        if pos < range.end && !see(0, &mut found) {
            return None;
        }
        found
    }

    /// Index of `author`, adding it if it is new. A human whose name is Me's is Me.
    pub fn author_index(&mut self, author: &Author) -> u32 {
        if let Some(i) = self.authors.iter().position(|a| a.author == *author) {
            return i as u32;
        }
        self.authors.push(AuthorEntry { author: author.clone(), from_file: false });
        let i = self.authors.len() as u32 - 1;
        self.order.push(i);
        i
    }

    // ----- edits ----------------------------------------------------------------------------

    /// Keeps the runs in step with a text edit: `range` was replaced by `inserted_len` units.
    ///
    /// Deleting shrinks or removes runs. The inserted text is attributed as follows: typing
    /// strictly inside a run splits it, and at a run's edge does not extend it, for `Typed`
    /// and `As`; `Inherit` takes the attribution of the character before the insertion point
    /// (after the deletion), or, when that character is unattributed or there is none, of the
    /// character after it, so it extends a neighbouring run; `None` leaves it unattributed.
    pub fn edit(&mut self, range: TextRange, inserted_len: u32, attribution: Attribution) {
        let s = range.start;
        let e = range.end.max(range.start);
        if e > s {
            self.delete(s, e);
        }
        if inserted_len == 0 {
            return;
        }
        let author = match &attribution {
            Attribution::Typed(a) | Attribution::As(a) => Some(self.author_index(a)),
            Attribution::Inherit => self.inherit_at(s),
            Attribution::None => None,
        };
        self.insert_gap(s, inserted_len);
        if let Some(a) = author {
            self.paint(s, s + inserted_len, Some(a));
        }
    }

    /// A replacement of `old` (at `range`) by `new`, as a programmatic edit produces: the
    /// characters both share keep their attribution, and only what is really inserted is
    /// attributed. `Inherit` diffs `old` against `new` so wrapping a mixed selection in `**`
    /// does not flatten it; the other attributions treat it as one replacement.
    pub fn edit_replacing(&mut self, range: TextRange, old: &str, new: &str, attribution: Attribution) {
        if !matches!(attribution, Attribution::Inherit) {
            let n = self.units(new);
            self.edit(range, n, attribution);
            return;
        }
        let mut shift: i64 = 0;
        for (at, del, ins) in diff::hunks(self.encoding, old, new) {
            let start = (range.start as i64 + at as i64 + shift) as u32;
            self.edit(TextRange::new(start, start + del), ins, Attribution::Inherit);
            shift += ins as i64 - del as i64;
        }
    }

    fn units(&self, s: &str) -> u32 {
        match self.encoding {
            OffsetEncoding::Utf8 => s.len() as u32,
            OffsetEncoding::Utf16 => s.encode_utf16().count() as u32,
            OffsetEncoding::Utf32 => s.chars().count() as u32,
        }
    }

    /// Mark As: attributes `range` to `author`, or clears it (`None`).
    pub fn mark(&mut self, range: TextRange, author: Option<&Author>) {
        if range.is_empty() {
            return;
        }
        let a = author.map(|a| self.author_index(a));
        self.paint(range.start, range.end, a);
    }

    fn inherit_at(&self, s: u32) -> Option<u32> {
        let before = if s > 0 { self.author_at(s - 1) } else { None };
        before.or_else(|| self.author_at(s))
    }

    fn delete(&mut self, s: u32, e: u32) {
        let d = e - s;
        let mut out: Vec<Run> = Vec::with_capacity(self.runs.len());
        for r in &self.runs {
            if r.end <= s {
                out.push(*r);
            } else if r.start >= e {
                out.push(Run { start: r.start - d, end: r.end - d, author: r.author });
            } else {
                if r.start < s {
                    out.push(Run { start: r.start, end: s, author: r.author });
                }
                if r.end > e {
                    out.push(Run { start: s, end: r.end - d, author: r.author });
                }
            }
        }
        self.runs = out;
        self.merge();
    }

    fn insert_gap(&mut self, s: u32, n: u32) {
        let mut out: Vec<Run> = Vec::with_capacity(self.runs.len() + 1);
        for r in &self.runs {
            if r.end <= s {
                out.push(*r);
            } else if r.start >= s {
                out.push(Run { start: r.start + n, end: r.end + n, author: r.author });
            } else {
                out.push(Run { start: r.start, end: s, author: r.author });
                out.push(Run { start: s + n, end: r.end + n, author: r.author });
            }
        }
        self.runs = out;
    }

    fn paint(&mut self, s: u32, e: u32, author: Option<u32>) {
        if e <= s {
            return;
        }
        let mut out: Vec<Run> = Vec::with_capacity(self.runs.len() + 2);
        let mut placed = author.is_none();
        for r in &self.runs {
            if r.end <= s {
                out.push(*r);
                continue;
            }
            if r.start >= e {
                if !placed {
                    out.push(Run { start: s, end: e, author: author.unwrap() });
                    placed = true;
                }
                out.push(*r);
                continue;
            }
            if r.start < s {
                out.push(Run { start: r.start, end: s, author: r.author });
            }
            if !placed {
                out.push(Run { start: s, end: e, author: author.unwrap() });
                placed = true;
            }
            if r.end > e {
                out.push(Run { start: e, end: r.end, author: r.author });
            }
        }
        if !placed {
            out.push(Run { start: s, end: e, author: author.unwrap() });
        }
        self.runs = out;
        self.merge();
    }

    pub(crate) fn merge(&mut self) {
        let mut out: Vec<Run> = Vec::with_capacity(self.runs.len());
        for r in self.runs.drain(..) {
            if r.start >= r.end {
                continue;
            }
            match out.last_mut() {
                Some(l) if l.end == r.start && l.author == r.author => l.end = r.end,
                _ => out.push(r),
            }
        }
        self.runs = out;
    }

    // ----- snapshots -------------------------------------------------------------------------

    pub fn snapshot(&self) -> AuthorshipSnapshot {
        let mut c = self.clone();
        c.origin = None;
        AuthorshipSnapshot(c)
    }

    /// Puts the attribution back exactly as it was when `snapshot` was taken. Me keeps the
    /// name it has now, and the file this was loaded from is remembered still.
    pub fn restore(&mut self, snapshot: &AuthorshipSnapshot) {
        let me = self.authors[0].author.name.clone();
        let origin = self.origin.take();
        *self = snapshot.0.clone();
        self.authors[0].author.name = me;
        self.origin = origin;
    }

    /// Equality of what the user can see and what would be written: runs and authors.
    pub fn same_state(&self, other: &Authorship) -> bool {
        self.runs == other.runs
            && self.authors == other.authors
            && self.order == other.order
            && self.unknown == other.unknown
            && self.hash_key == other.hash_key
    }
}
