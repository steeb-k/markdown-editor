//! UniFFI surface of `markdown_core::authorship`. Mirrors records and forwards calls; no
//! logic. Ranges are UTF-16 code units, except `GraphemeRange`, which is in grapheme
//! clusters because that is what the file format counts.

use std::sync::{Arc, Mutex};

use markdown_core as core;
use markdown_core::authorship as ca;

use crate::Utf16Range;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AuthorKind {
    Human,
    Ai,
    Reference,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Author {
    pub kind: AuthorKind,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Attribution {
    Typed { author: Author },
    Pasted { author: Author },
    Inherit,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AuthorRun {
    pub range: Utf16Range,
    pub author_index: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AnnotationLineEnding {
    Lf,
    CrLf,
    Cr,
    Preserve,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AnnotationStatus {
    Absent,
    Valid,
    HashMismatch,
    Malformed { reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct GraphemeRange {
    pub start: u32,
    pub length: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedAuthor {
    pub kind: AuthorKind,
    pub name: String,
    pub ranges: Vec<GraphemeRange>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedAnnotations {
    pub hash_key: String,
    pub hash_range: GraphemeRange,
    pub algorithm: String,
    pub hash: String,
    pub authors: Vec<ParsedAuthor>,
    pub unknown: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SplitFile {
    pub body: String,
    pub annotations: Option<ParsedAnnotations>,
    pub status: AnnotationStatus,
    pub raw_tail: Option<String>,
}

// ----- conversions ---------------------------------------------------------------------------

impl From<AuthorKind> for ca::AuthorKind {
    fn from(k: AuthorKind) -> Self {
        match k {
            AuthorKind::Human => Self::Human,
            AuthorKind::Ai => Self::Ai,
            AuthorKind::Reference => Self::Reference,
        }
    }
}
impl From<ca::AuthorKind> for AuthorKind {
    fn from(k: ca::AuthorKind) -> Self {
        match k {
            ca::AuthorKind::Human => Self::Human,
            ca::AuthorKind::Ai => Self::Ai,
            ca::AuthorKind::Reference => Self::Reference,
        }
    }
}
impl From<Author> for ca::Author {
    fn from(a: Author) -> Self {
        ca::Author { kind: a.kind.into(), name: a.name }
    }
}
impl From<ca::Author> for Author {
    fn from(a: ca::Author) -> Self {
        Author { kind: a.kind.into(), name: a.name }
    }
}
impl From<Attribution> for ca::Attribution {
    fn from(a: Attribution) -> Self {
        match a {
            Attribution::Typed { author } => Self::Typed(author.into()),
            Attribution::Pasted { author } => Self::As(author.into()),
            Attribution::Inherit => Self::Inherit,
            Attribution::None => Self::None,
        }
    }
}
impl From<AnnotationLineEnding> for ca::LineEnding {
    fn from(e: AnnotationLineEnding) -> Self {
        match e {
            AnnotationLineEnding::Lf => Self::Lf,
            AnnotationLineEnding::CrLf => Self::CrLf,
            AnnotationLineEnding::Cr => Self::Cr,
            AnnotationLineEnding::Preserve => Self::Preserve,
        }
    }
}
impl From<ca::AnnotationStatus> for AnnotationStatus {
    fn from(s: ca::AnnotationStatus) -> Self {
        match s {
            ca::AnnotationStatus::Absent => Self::Absent,
            ca::AnnotationStatus::Valid => Self::Valid,
            ca::AnnotationStatus::HashMismatch => Self::HashMismatch,
            ca::AnnotationStatus::Malformed(reason) => Self::Malformed { reason },
        }
    }
}
impl From<ca::GraphemeRange> for GraphemeRange {
    fn from(r: ca::GraphemeRange) -> Self {
        Self { start: r.start, length: r.length }
    }
}
impl From<GraphemeRange> for ca::GraphemeRange {
    fn from(r: GraphemeRange) -> Self {
        Self { start: r.start, length: r.length }
    }
}
impl From<ca::ParsedAuthor> for ParsedAuthor {
    fn from(p: ca::ParsedAuthor) -> Self {
        Self { kind: p.kind.into(), name: p.name, ranges: p.ranges.into_iter().map(Into::into).collect() }
    }
}
impl From<ParsedAuthor> for ca::ParsedAuthor {
    fn from(p: ParsedAuthor) -> Self {
        Self { kind: p.kind.into(), name: p.name, ranges: p.ranges.into_iter().map(Into::into).collect() }
    }
}
impl From<ca::ParsedAnnotations> for ParsedAnnotations {
    fn from(p: ca::ParsedAnnotations) -> Self {
        Self {
            hash_key: p.hash_key,
            hash_range: p.hash_range.into(),
            algorithm: p.algorithm,
            hash: p.hash,
            authors: p.authors.into_iter().map(Into::into).collect(),
            unknown: p.unknown,
        }
    }
}
impl From<ParsedAnnotations> for ca::ParsedAnnotations {
    fn from(p: ParsedAnnotations) -> Self {
        Self {
            hash_key: p.hash_key,
            hash_range: p.hash_range.into(),
            algorithm: p.algorithm,
            hash: p.hash,
            authors: p.authors.into_iter().map(Into::into).collect(),
            unknown: p.unknown,
        }
    }
}

/// Separates the annotation block from the text of a file as it is on disk.
#[uniffi::export]
pub fn split_annotations(file_text: String) -> SplitFile {
    let s = ca::split_annotations(&file_text);
    SplitFile {
        body: s.body,
        annotations: s.annotations.map(Into::into),
        status: s.status.into(),
        raw_tail: s.raw_tail,
    }
}

// ----- the object ---------------------------------------------------------------------------

/// Which author each character belongs to. Ranges are in UTF-16 code units.
#[derive(uniffi::Object)]
pub struct Authorship {
    inner: Mutex<ca::Authorship>,
}

/// A copy of the attribution for undo.
#[derive(uniffi::Object)]
pub struct AuthorshipSnapshot {
    inner: ca::AuthorshipSnapshot,
}

#[uniffi::export]
impl AuthorshipSnapshot {
    pub fn equals(&self, other: Arc<AuthorshipSnapshot>) -> bool {
        self.inner == other.inner
    }
}

impl Authorship {
    fn with<R>(&self, f: impl FnOnce(&mut ca::Authorship) -> R) -> R {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard)
    }
}

#[uniffi::export]
impl Authorship {
    /// No attribution; `me` is the name of the Human author who is Me.
    #[uniffi::constructor]
    pub fn new(me: String) -> Self {
        Self { inner: Mutex::new(ca::Authorship::with_me(core::OffsetEncoding::Utf16, &me)) }
    }

    /// The attribution a file's annotations describe. `body` is the text as the editor holds
    /// it (`\n` line endings).
    #[uniffi::constructor]
    pub fn from_annotations(body: String, annotations: ParsedAnnotations, me: String) -> Self {
        let parsed: ca::ParsedAnnotations = annotations.into();
        Self {
            inner: Mutex::new(ca::Authorship::from_annotations(
                &body,
                &parsed,
                core::OffsetEncoding::Utf16,
                &me,
            )),
        }
    }

    pub fn me(&self) -> Author {
        self.with(|a| a.me().clone().into())
    }

    pub fn set_me_name(&self, name: String) {
        self.with(|a| a.set_me_name(&name))
    }

    pub fn authors(&self) -> Vec<Author> {
        self.with(|a| a.authors().into_iter().map(Into::into).collect())
    }

    pub fn author_index(&self, author: Author) -> u32 {
        self.with(|a| a.author_index(&author.into()))
    }

    pub fn has_marks(&self) -> bool {
        self.with(|a| a.has_marks())
    }

    pub fn runs(&self, within: Option<Utf16Range>) -> Vec<AuthorRun> {
        self.with(|a| {
            a.runs(within.map(Into::into))
                .into_iter()
                .map(|r| AuthorRun { range: r.range.into(), author_index: r.author_index })
                .collect()
        })
    }

    pub fn author_at(&self, position: u32) -> Option<u32> {
        self.with(|a| a.author_at(position))
    }

    pub fn uniform_author(&self, range: Utf16Range) -> Option<u32> {
        self.with(|a| a.uniform_author(range.into()))
    }

    pub fn edit(&self, range: Utf16Range, inserted_len: u32, attribution: Attribution) {
        self.with(|a| a.edit(range.into(), inserted_len, attribution.into()))
    }

    pub fn edit_replacing(&self, range: Utf16Range, old: String, new: String, attribution: Attribution) {
        self.with(|a| a.edit_replacing(range.into(), &old, &new, attribution.into()))
    }

    pub fn mark(&self, range: Utf16Range, author: Option<Author>) {
        self.with(|a| a.mark(range.into(), author.map(ca::Author::from).as_ref()))
    }

    pub fn snapshot(&self) -> Arc<AuthorshipSnapshot> {
        self.with(|a| Arc::new(AuthorshipSnapshot { inner: a.snapshot() }))
    }

    pub fn restore(&self, snapshot: Arc<AuthorshipSnapshot>) {
        self.with(|a| a.restore(&snapshot.inner))
    }

    pub fn annotation_block(&self, text: String, ending: AnnotationLineEnding) -> Option<String> {
        self.with(|a| a.annotation_block(&text, ending.into()))
    }

    pub fn set_origin(&self, body: String, raw_tail: String, ending: AnnotationLineEnding) {
        self.with(|a| a.set_origin(&body, &raw_tail, ending.into()))
    }

    pub fn clear_origin(&self) {
        self.with(|a| a.clear_origin())
    }

    pub fn file_tail(&self, text: String, ending: AnnotationLineEnding) -> String {
        self.with(|a| a.file_tail(&text, ending.into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_through_the_ffi_types() {
        let a = Authorship::new("Me".into());
        let ai = Author { kind: AuthorKind::Ai, name: "AI".into() };
        a.edit(Utf16Range { start: 0, end: 0 }, 5, Attribution::Pasted { author: ai.clone() });
        a.edit(Utf16Range { start: 2, end: 2 }, 2, Attribution::Typed { author: a.me() });
        assert!(a.has_marks());
        let tail = a.file_tail("ab\u{1F600}cd!\n".into(), AnnotationLineEnding::Lf);
        let file = format!("ab\u{1F600}cd!\n{tail}");
        let s = split_annotations(file);
        assert_eq!(s.status, AnnotationStatus::Valid);
        let b = Authorship::from_annotations(s.body, s.annotations.unwrap(), "Me".into());
        assert_eq!(a.runs(None), b.runs(None));
        let snap = a.snapshot();
        a.mark(Utf16Range { start: 0, end: 6 }, None);
        a.restore(snap.clone());
        assert!(a.snapshot().equals(snap));
    }
}
