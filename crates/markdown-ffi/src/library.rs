//! UniFFI surface of `markdown_core::library`. Mirrors records and forwards calls; no logic. The
//! library is created with UTF-16 offsets, so every range in it is in UTF-16 code units; it sits
//! behind a `Mutex`, like `Document`. Names that Swift might find ambiguous are prefixed.

use std::collections::HashMap;
use std::sync::Mutex;

use markdown_core as core;
use markdown_core::library as cl;

use crate::Utf16Range;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteRef {
    pub root: String,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryRoot {
    pub id: String,
    pub path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum LibraryError {
    UnknownRoot,
    NoSuchNote,
}

impl std::fmt::Display for LibraryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        cl::LibraryError::from(*self).fmt(f)
    }
}

impl std::error::Error for LibraryError {}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteInput {
    pub note: NoteRef,
    pub text: String,
    pub modified: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteInfo {
    pub note: NoteRef,
    pub title: String,
    pub tags: Vec<String>,
    pub aliases: Vec<String>,
    pub word_count: u32,
    pub modified: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeadingInfo {
    pub level: u8,
    pub text: String,
    pub range: Utf16Range,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkInfo {
    pub target: String,
    pub label: Option<String>,
    pub heading: Option<String>,
    pub range: Utf16Range,
    pub resolved: Option<NoteRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteMeta {
    pub info: NoteInfo,
    pub front_tags: Vec<String>,
    pub inline_tags: Vec<String>,
    pub headings: Vec<HeadingInfo>,
    pub links: Vec<LinkInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagCount {
    pub tag: String,
    pub count: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct LibraryFilter {
    #[uniffi(default = None)]
    pub root: Option<String>,
    #[uniffi(default = None)]
    pub folder: Option<String>,
    #[uniffi(default = [])]
    pub tags: Vec<String>,
    #[uniffi(default = None)]
    pub text: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LibrarySort {
    NameAscending,
    NameDescending,
    ModifiedNewest,
    ModifiedOldest,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchHit {
    pub note: NoteRef,
    pub title: String,
    pub snippet: String,
    pub highlights: Vec<Utf16Range>,
    pub title_match: bool,
    pub occurrences: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuickOpenMatch {
    pub note: NoteRef,
    pub title: String,
    pub score: i32,
    pub title_ranges: Vec<Utf16Range>,
    pub path_ranges: Vec<Utf16Range>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteBacklink {
    pub from: NoteRef,
    pub from_title: String,
    pub range: Utf16Range,
    pub context: String,
}

/// A place another note names a note without linking it (see `Library::mentions`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteMention {
    /// The note that is mentioned.
    pub to: NoteRef,
    pub from: NoteRef,
    pub from_title: String,
    pub range: Utf16Range,
    pub context: String,
    /// The title, file stem or alias that matched.
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryEdit {
    pub note: NoteRef,
    pub range: Utf16Range,
    pub replacement: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteTemplate {
    pub text: String,
    pub cursor: u32,
}

// ----- conversions (field-by-field, no logic) -----------------------------------------------

impl From<NoteRef> for cl::NoteRef {
    fn from(n: NoteRef) -> Self {
        cl::NoteRef { root: n.root, path: n.path }
    }
}
impl From<cl::NoteRef> for NoteRef {
    fn from(n: cl::NoteRef) -> Self {
        NoteRef { root: n.root, path: n.path }
    }
}
impl From<cl::Root> for LibraryRoot {
    fn from(r: cl::Root) -> Self {
        LibraryRoot { id: r.id, path: r.path }
    }
}
impl From<LibraryError> for cl::LibraryError {
    fn from(e: LibraryError) -> Self {
        match e {
            LibraryError::UnknownRoot => cl::LibraryError::UnknownRoot,
            LibraryError::NoSuchNote => cl::LibraryError::NoSuchNote,
        }
    }
}
impl From<cl::LibraryError> for LibraryError {
    fn from(e: cl::LibraryError) -> Self {
        match e {
            cl::LibraryError::UnknownRoot => LibraryError::UnknownRoot,
            cl::LibraryError::NoSuchNote => LibraryError::NoSuchNote,
        }
    }
}
impl From<NoteInput> for cl::NoteInput {
    fn from(n: NoteInput) -> Self {
        cl::NoteInput { note: n.note.into(), text: n.text, modified: n.modified }
    }
}
impl From<cl::NoteInfo> for NoteInfo {
    fn from(n: cl::NoteInfo) -> Self {
        NoteInfo { note: n.note.into(), title: n.title, tags: n.tags, aliases: n.aliases, word_count: n.word_count, modified: n.modified }
    }
}
impl From<cl::NoteMeta> for NoteMeta {
    fn from(m: cl::NoteMeta) -> Self {
        NoteMeta {
            info: m.info.into(),
            front_tags: m.front_tags,
            inline_tags: m.inline_tags,
            headings: m.headings.into_iter().map(|h| HeadingInfo { level: h.level, text: h.text, range: h.range.into() }).collect(),
            links: m
                .links
                .into_iter()
                .map(|l| LinkInfo {
                    target: l.target,
                    label: l.label,
                    heading: l.heading,
                    range: l.range.into(),
                    resolved: l.resolved.map(Into::into),
                })
                .collect(),
        }
    }
}
impl From<LibraryFilter> for cl::Filter {
    fn from(f: LibraryFilter) -> Self {
        cl::Filter { root: f.root, folder: f.folder, tags: f.tags, text: f.text }
    }
}
impl From<LibrarySort> for cl::Sort {
    fn from(s: LibrarySort) -> Self {
        match s {
            LibrarySort::NameAscending => cl::Sort::NameAscending,
            LibrarySort::NameDescending => cl::Sort::NameDescending,
            LibrarySort::ModifiedNewest => cl::Sort::ModifiedNewest,
            LibrarySort::ModifiedOldest => cl::Sort::ModifiedOldest,
        }
    }
}
impl From<cl::Hit> for SearchHit {
    fn from(h: cl::Hit) -> Self {
        SearchHit {
            note: h.note.into(),
            title: h.title,
            snippet: h.snippet,
            highlights: h.highlights.into_iter().map(Into::into).collect(),
            title_match: h.title_match,
            occurrences: h.occurrences,
        }
    }
}
impl From<cl::Match> for QuickOpenMatch {
    fn from(m: cl::Match) -> Self {
        QuickOpenMatch {
            note: m.note.into(),
            title: m.title,
            score: m.score,
            title_ranges: m.title_ranges.into_iter().map(Into::into).collect(),
            path_ranges: m.path_ranges.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<cl::Backlink> for NoteBacklink {
    fn from(b: cl::Backlink) -> Self {
        NoteBacklink { from: b.from.into(), from_title: b.from_title, range: b.range.into(), context: b.context }
    }
}
impl From<cl::Mention> for NoteMention {
    fn from(m: cl::Mention) -> Self {
        NoteMention {
            to: m.to.into(),
            from: m.from.into(),
            from_title: m.from_title,
            range: m.range.into(),
            context: m.context,
            name: m.name,
        }
    }
}
impl From<NoteMention> for cl::Mention {
    fn from(m: NoteMention) -> Self {
        cl::Mention {
            to: m.to.into(),
            from: m.from.into(),
            from_title: m.from_title,
            range: m.range.into(),
            context: m.context,
            name: m.name,
        }
    }
}
impl From<cl::Edit> for LibraryEdit {
    fn from(e: cl::Edit) -> Self {
        LibraryEdit { note: e.note.into(), range: e.range.into(), replacement: e.replacement }
    }
}

// ----- the library object ----------------------------------------------------------------------

/// The notes library. Every range crossing this API is in UTF-16 code units.
#[derive(uniffi::Object)]
pub struct Library {
    inner: Mutex<cl::Library>,
}

impl Library {
    fn with<R>(&self, f: impl FnOnce(&mut cl::Library) -> R) -> R {
        // A poisoned lock only means a previous call panicked; the index is still usable.
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard)
    }
}

#[uniffi::export]
impl Library {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self { inner: Mutex::new(cl::Library::new(core::OffsetEncoding::Utf16)) }
    }

    pub fn len(&self) -> u64 {
        self.with(|l| l.len() as u64)
    }

    pub fn is_empty(&self) -> bool {
        self.with(|l| l.is_empty())
    }

    pub fn add_root(&self, id: String, path: String) {
        self.with(|l| l.add_root(&id, &path))
    }

    pub fn remove_root(&self, id: String) -> bool {
        self.with(|l| l.remove_root(&id))
    }

    pub fn roots(&self) -> Vec<LibraryRoot> {
        self.with(|l| l.roots().into_iter().map(Into::into).collect())
    }

    pub fn upsert(&self, note: NoteRef, text: String, modified: i64) -> Result<(), LibraryError> {
        self.with(|l| l.upsert(&note.into(), &text, modified).map_err(Into::into))
    }

    pub fn upsert_all(&self, items: Vec<NoteInput>) -> Result<(), LibraryError> {
        self.with(|l| l.upsert_all(items.into_iter().map(Into::into).collect()).map_err(Into::into))
    }

    pub fn remove(&self, note: NoteRef) -> bool {
        self.with(|l| l.remove(&note.into()))
    }

    pub fn rename(&self, old: NoteRef, new: NoteRef) -> Result<(), LibraryError> {
        self.with(|l| l.rename(&old.into(), &new.into()).map_err(Into::into))
    }

    pub fn note(&self, note: NoteRef) -> Option<NoteMeta> {
        self.with(|l| l.note(&note.into()).map(Into::into))
    }

    pub fn tags(&self) -> Vec<TagCount> {
        self.with(|l| l.tags().into_iter().map(|t| TagCount { tag: t.tag, count: t.count }).collect())
    }

    pub fn notes(&self, filter: LibraryFilter, sort: LibrarySort) -> Vec<NoteInfo> {
        self.with(|l| l.notes(&filter.into(), sort.into()).into_iter().map(Into::into).collect())
    }

    pub fn search(&self, query: String, limit: u32) -> Vec<SearchHit> {
        self.with(|l| l.search(&query, limit as usize).into_iter().map(Into::into).collect())
    }

    pub fn quick_open(&self, query: String, limit: u32) -> Vec<QuickOpenMatch> {
        self.with(|l| l.quick_open(&query, limit as usize).into_iter().map(Into::into).collect())
    }

    pub fn resolve_wikilink(&self, from: NoteRef, target: String) -> Option<NoteRef> {
        self.with(|l| l.resolve_wikilink(&from.into(), &target).map(Into::into))
    }

    pub fn backlinks(&self, note: NoteRef) -> Vec<NoteBacklink> {
        self.with(|l| l.backlinks(&note.into()).into_iter().map(Into::into).collect())
    }

    /// The notes that name `note` (by title, file stem or alias) without linking it.
    pub fn mentions(&self, note: NoteRef) -> Vec<NoteMention> {
        self.with(|l| l.mentions(&note.into()).into_iter().map(Into::into).collect())
    }

    /// The edit that wraps a mention in a wikilink; `None` when the text has changed since.
    pub fn link_mention_edit(&self, mention: NoteMention) -> Option<LibraryEdit> {
        self.with(|l| l.link_mention_edit(&mention.into()).map(Into::into))
    }

    pub fn rename_targets(&self, old_title: String, new_title: String) -> Vec<LibraryEdit> {
        self.with(|l| l.rename_targets(&old_title, &new_title).into_iter().map(Into::into).collect())
    }

    /// The link edits for moving `old` to `new`; ask before `rename`.
    pub fn rename_edits(&self, old: NoteRef, new: NoteRef) -> Vec<LibraryEdit> {
        self.with(|l| l.rename_edits(&old.into(), &new.into()).into_iter().map(Into::into).collect())
    }
}

impl Default for Library {
    fn default() -> Self {
        Self::new()
    }
}

/// Fills `{{date}}`-style placeholders; the cursor is in UTF-16 code units.
#[uniffi::export]
pub fn expand_template(text: String, vars: HashMap<String, String>) -> NoteTemplate {
    let t = cl::expand_template(&text, &vars, core::OffsetEncoding::Utf16);
    NoteTemplate { text: t.text, cursor: t.cursor }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let lib = Library::new();
        lib.add_root("a".into(), "/a".into());
        let note = NoteRef { root: "a".into(), path: "x.md".into() };
        lib.upsert(note.clone(), "\u{1F389} [[Target]] #tag".into(), 1).unwrap();
        lib.upsert(NoteRef { root: "a".into(), path: "Target.md".into() }, "# Target".into(), 2).unwrap();
        let meta = lib.note(note).unwrap();
        // The emoji is two UTF-16 units.
        assert_eq!(meta.links[0].range, Utf16Range { start: 3, end: 13 });
        assert_eq!(meta.links[0].resolved.as_ref().map(|n| n.path.as_str()), Some("Target.md"));
        assert_eq!(lib.backlinks(NoteRef { root: "a".into(), path: "Target.md".into() }).len(), 1);
        assert_eq!(lib.upsert(NoteRef { root: "zz".into(), path: "x.md".into() }, String::new(), 0), Err(LibraryError::UnknownRoot));
        let t = expand_template("a{{cursor}}\u{1F389}{{x}}".into(), [("x".to_owned(), "!".to_owned())].into());
        assert_eq!((t.text.as_str(), t.cursor), ("a\u{1F389}!", 1));
    }

    /// Every range the FFI hands out is in UTF-16 units, past emoji (two units) and CJK (one).
    #[test]
    fn ranges_are_utf16_past_emoji_and_cjk() {
        fn slice(s: &str, r: &Utf16Range) -> String {
            let u: Vec<u16> = s.encode_utf16().collect();
            String::from_utf16(&u[r.start as usize..r.end as usize]).unwrap()
        }
        let lib = Library::new();
        lib.add_root("a".into(), "/a".into());
        let n = |p: &str| NoteRef { root: "a".into(), path: p.into() };
        let src = "# \u{65E5}\u{672C} \u{1F389}\n\n\u{1F389}\u{1F389} \u{691C}\u{7D22} [[\u{30CE}\u{30FC}\u{30C8}|\u{1F389}]] needle";
        let target = "# \u{1F389} \u{30CE}\u{30FC}\u{30C8}";
        lib.upsert(n("src.md"), src.into(), 1).unwrap();
        lib.upsert(n("\u{30CE}\u{30FC}\u{30C8}.md"), target.into(), 2).unwrap();
        let meta = lib.note(n("src.md")).unwrap();
        assert_eq!(slice(src, &meta.headings[0].range), "# \u{65E5}\u{672C} \u{1F389}");
        assert_eq!(slice(src, &meta.links[0].range), "[[\u{30CE}\u{30FC}\u{30C8}|\u{1F389}]]");
        let b = lib.backlinks(n("\u{30CE}\u{30FC}\u{30C8}.md"));
        assert_eq!(slice(src, &b[0].range), "[[\u{30CE}\u{30FC}\u{30C8}|\u{1F389}]]");
        let hit = &lib.search("needle".into(), 5)[0];
        assert_eq!(slice(&hit.snippet, &hit.highlights[0]), "needle");
        let hit = &lib.search("\u{7D22}".into(), 5)[0];
        assert_eq!(slice(&hit.snippet, &hit.highlights[0]), "\u{7D22}");
        let m = &lib.quick_open("\u{30FC}\u{30C8}".into(), 5)[0];
        assert_eq!(slice(&m.title, &m.title_ranges[0]), "\u{30FC}\u{30C8}");
        let e = lib.rename_edits(n("\u{30CE}\u{30FC}\u{30C8}.md"), n("\u{1F389}.md"));
        assert_eq!((slice(src, &e[0].range).as_str(), e[0].replacement.as_str()), ("\u{30CE}\u{30FC}\u{30C8}", "\u{1F389}"));
        let e = lib.rename_targets("\u{30CE}\u{30FC}\u{30C8}".into(), "x".into());
        assert_eq!(slice(src, &e[0].range), "\u{30CE}\u{30FC}\u{30C8}");
    }
}
