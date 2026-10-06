//! The library: an index over a set of notes (Markdown files in folders) that the shell feeds and
//! the core never reads from disk. It knows titles, tags, wikilinks and headings of every note,
//! answers full-text search and quick open, resolves wikilinks, and keeps the link graph
//! (backlinks) up to date as notes come, go, change and are renamed.
//!
//! * **Paths** are UTF-8 strings relative to a root (`Daily/2026-10-03.md`, `/` separators), a
//!   note is named by a [`NoteRef`]: root id and path. Roots are added by the shell
//!   ([`Library::add_root`]); the path a root has on disk is the shell's business.
//! * **Offsets** crossing the API (a wikilink's range, snippet highlights, rename edits) are in
//!   the unit of the encoding the library was created with, like [`crate::Document`]'s. The
//!   library keeps each note's text for that, for snippets and for backlink contexts.
//! * **Incremental**: [`Library::upsert`] re-indexes one note and patches the link graph (the
//!   links that name it, by title or file stem, are resolved again; nothing else is). Starting
//!   up is [`Library::upsert_all`], which parses on all cores.
//! * **Resolution**: `[[Target]]` is the note whose file stem or title equals `Target`, case
//!   folded, with an extension ignored; with a `/` in it, `folder/Note` also matches a path
//!   ending that way. With several candidates the nearest folder wins (same root first, then
//!   the longest shared folder prefix, then the shallowest), then a file stem over a title,
//!   then root order and path, so the result never depends on the order notes were added in.
//!   `[[#Heading]]` is the note itself. Nothing found is `None`: the shell offers to create it.
//! * **Tags** are lower case without the `#`; front matter and inline tags are merged.
//!   `a/b` is under `a`: a filter for `a` takes `a/b` too.
//! * **Search** is a small inverted index of case-folded words (every ideographic character
//!   is a word): the query's words must each prefix a word of the note; title (and file name)
//!   matches first, then how often the words occur. No normalisation form is applied, so a
//!   decomposed `e` + U+0301 and a precomposed `\u{e9}` are different.
//!
//! `Library` holds plain data only, so it is `Send + Sync`; the shell keeps it behind a lock.

mod fuzzy;
mod search;
mod template;
mod text;

use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};

pub use template::{expand_template, Template};

use crate::analysis::analyze;
use crate::offsets::OffsetMap;
use crate::types::{OffsetEncoding, SpanKind, TextRange};
use crate::wiki;

/// A note: the id of its root and its path inside it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NoteRef {
    pub root: String,
    pub path: String,
}

impl NoteRef {
    pub fn new(root: &str, path: &str) -> Self {
        Self { root: root.to_owned(), path: path.to_owned() }
    }
}

/// A folder the library draws notes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Root {
    pub id: String,
    /// Where it is on disk. Kept for the shell; the core never opens it.
    pub path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryError {
    /// The note's root has not been added.
    UnknownRoot,
    /// The note is not in the library.
    NoSuchNote,
}

impl std::fmt::Display for LibraryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            LibraryError::UnknownRoot => "the root has not been added",
            LibraryError::NoSuchNote => "there is no such note",
        })
    }
}

impl std::error::Error for LibraryError {}

/// A note to index (see [`Library::upsert_all`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteInput {
    pub note: NoteRef,
    pub text: String,
    /// Modification time, in whatever unit the shell likes (seconds since the epoch);
    /// only compared.
    pub modified: i64,
}

/// What the list of notes needs to know about one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteInfo {
    pub note: NoteRef,
    /// The first level 1 heading, else the file stem.
    pub title: String,
    /// Front matter and inline tags together, sorted, without duplicates.
    pub tags: Vec<String>,
    pub word_count: u32,
    pub modified: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadingInfo {
    pub level: u8,
    /// Without markup.
    pub text: String,
    /// The whole heading in the note's text.
    pub range: TextRange,
}

/// An outgoing wikilink.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkInfo {
    pub target: String,
    pub label: Option<String>,
    pub heading: Option<String>,
    /// The whole `[[...]]` in the note's text.
    pub range: TextRange,
    /// The note it resolves to, if any.
    pub resolved: Option<NoteRef>,
}

/// Everything the index knows about one note, apart from its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteMeta {
    pub info: NoteInfo,
    pub front_tags: Vec<String>,
    pub inline_tags: Vec<String>,
    pub headings: Vec<HeadingInfo>,
    pub links: Vec<LinkInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagCount {
    pub tag: String,
    /// Notes carrying exactly this tag.
    pub count: u32,
}

/// What [`Library::notes`] keeps. Every part that is set must hold.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Filter {
    pub root: Option<String>,
    /// A folder inside the root (or every root): the notes below it, however deep.
    pub folder: Option<String>,
    /// All of these tags (a tag also matches its sub-tags).
    pub tags: Vec<String>,
    /// Free text: the notes a search for it finds.
    pub text: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sort {
    /// By file name, case-folded, then path.
    NameAscending,
    NameDescending,
    /// Newest first.
    ModifiedNewest,
    ModifiedOldest,
}

/// A search result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub note: NoteRef,
    pub title: String,
    /// Some words of the note around the first match (one line, at most about 160 characters).
    pub snippet: String,
    /// The matched words inside `snippet`.
    pub highlights: Vec<TextRange>,
    /// A query word matches a word of the title or file name.
    pub title_match: bool,
    /// How often the query's words occur in the note.
    pub occurrences: u32,
}

/// A quick open result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    pub note: NoteRef,
    pub title: String,
    pub score: i32,
    /// Matched characters of the title, merged into runs; empty when the path matched better.
    pub title_ranges: Vec<TextRange>,
    /// Matched characters of the path (with its extension), merged into runs.
    pub path_ranges: Vec<TextRange>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Backlink {
    pub from: NoteRef,
    pub from_title: String,
    /// The wikilink in the linking note's text.
    pub range: TextRange,
    /// The sentence the link is in.
    pub context: String,
}

/// A change the shell applies when a note is renamed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edit {
    pub note: NoteRef,
    pub range: TextRange,
    pub replacement: String,
}

// ----- internals ----------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Link {
    /// The target as written.
    target: String,
    /// Lower case, without a note extension: what resolution compares.
    key: String,
    label: Option<String>,
    heading: Option<String>,
    /// Byte ranges: the whole link, and its target.
    start: usize,
    end: usize,
    target_start: usize,
    target_end: usize,
}

#[derive(Debug, Clone)]
struct Heading {
    level: u8,
    text: String,
    start: usize,
    end: usize,
}

/// What parsing one note yields; independent of the library, so it can run on any thread.
struct Parsed {
    h1: Option<String>,
    front_tags: Vec<String>,
    inline_tags: Vec<String>,
    links: Vec<Link>,
    headings: Vec<Heading>,
    words: u32,
    terms: Vec<(String, u32)>,
    /// Where the text after the front matter starts.
    body_start: usize,
}

#[derive(Debug, Clone)]
struct Note {
    r: NoteRef,
    text: String,
    map: OffsetMap,
    modified: i64,
    /// The file name without its extension.
    stem: String,
    h1: Option<String>,
    front_tags: Vec<String>,
    inline_tags: Vec<String>,
    tags: Vec<String>,
    links: Vec<Link>,
    /// Slots the links resolve to, one per link.
    resolved: Vec<Option<u32>>,
    headings: Vec<Heading>,
    words: u32,
    body_start: usize,
    /// Terms in the inverted index.
    term_ids: Vec<u32>,
    /// Case-folded stem and title: what links name the note by.
    names: Vec<String>,
}

impl Note {
    fn title(&self) -> &str {
        self.h1.as_deref().unwrap_or(&self.stem)
    }
}

/// The index. See the module documentation.
#[derive(Debug, Clone)]
pub struct Library {
    encoding: OffsetEncoding,
    roots: Vec<Root>,
    notes: Vec<Option<Note>>,
    free: Vec<u32>,
    by_ref: HashMap<NoteRef, u32>,
    /// Name (case-folded stem or title) to the notes called that.
    names: HashMap<String, Vec<u32>>,
    /// What links name (the whole key, and its last path component) to the notes linking there.
    link_names: HashMap<String, HashSet<u32>>,
    /// Slot to the notes, other than itself, with a link resolved to it.
    incoming: HashMap<u32, HashSet<u32>>,
    index: search::Inverted,
}

const EXTENSIONS: [&str; 4] = ["md", "markdown", "mdown", "txt"];

/// The file name of `path` without its extension.
fn stem_of(path: &str) -> &str {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rfind('.') {
        Some(dot) if dot > 0 => &name[..dot],
        _ => name,
    }
}

/// `path` without a note extension.
fn without_extension(path: &str) -> &str {
    if let Some(dot) = path.rfind('.') {
        let ext = &path[dot + 1..];
        if EXTENSIONS.iter().any(|e| ext.eq_ignore_ascii_case(e)) {
            return &path[..dot];
        }
    }
    path
}

/// What resolution compares: trimmed, no note extension, normalised and case-folded (`text::key`).
fn link_key(target: &str) -> String {
    text::key(without_extension(target.trim()).trim_start_matches("./"))
}

/// The names a link is registered under: its key, and the last path component of it.
fn link_names_of(key: &str) -> Vec<&str> {
    match key.rfind('/') {
        Some(slash) if slash + 1 < key.len() => vec![key, &key[slash + 1..]],
        _ => vec![key],
    }
}

fn folder_of(path: &str) -> &str {
    path.rfind('/').map_or("", |i| &path[..i])
}

/// Parses one note. Pure.
fn parse(text: &str) -> Parsed {
    let a = analyze(text);
    let mut h1 = None;
    let mut front_tags = Vec::new();
    let mut inline_tags = Vec::new();
    let mut links = Vec::new();
    let mut headings = Vec::new();
    let mut body_start = 0;
    let spans = &a.spans;
    for (i, sp) in spans.iter().enumerate() {
        match sp.kind {
            SpanKind::FrontMatter if sp.start == 0 => {
                body_start = sp.end;
                front_tags = text::front_matter_tags(&text[sp.start..sp.end]);
            }
            SpanKind::Heading { level } => {
                // The text, minus the markup nested in it (`#`, emphasis marks, backticks).
                let mut plain = String::new();
                let mut at = sp.start;
                for m in spans[i + 1..].iter().take_while(|m| m.start < sp.end) {
                    if m.kind == SpanKind::Markup && m.start >= at {
                        plain.push_str(&text[at..m.start]);
                        at = m.end;
                    }
                }
                plain.push_str(&text[at..sp.end]);
                let plain = plain.split_whitespace().collect::<Vec<_>>().join(" ");
                if level == 1 && h1.is_none() && !plain.is_empty() {
                    h1 = Some(plain.clone());
                }
                headings.push(Heading { level, text: plain, start: sp.start, end: sp.end });
            }
            SpanKind::Wikilink => {
                if let Some(w) = wiki::parse_wikilink(text, sp.start, sp.end) {
                    let get = |r: (usize, usize)| text[r.0..r.1].to_owned();
                    let target = get(w.target);
                    links.push(Link {
                        key: link_key(&target),
                        target,
                        label: w.label.map(get),
                        heading: w.heading.map(get),
                        start: w.start,
                        end: w.end,
                        target_start: w.target.0,
                        target_end: w.target.1,
                    });
                }
            }
            SpanKind::Tag => inline_tags.push(text::normalize_tag(&text[sp.start + 1..sp.end])),
            _ => {}
        }
    }
    front_tags.sort();
    front_tags.dedup();
    inline_tags.sort();
    inline_tags.dedup();
    let (terms, _) = text::term_counts(text);
    let mut words = 0u32;
    text::for_each_word(&text[body_start..], |_, _, _| words = words.saturating_add(1));
    Parsed { h1, front_tags, inline_tags, links, headings, words, terms, body_start }
}

impl Library {
    pub fn new(encoding: OffsetEncoding) -> Self {
        Self {
            encoding,
            roots: Vec::new(),
            notes: Vec::new(),
            free: Vec::new(),
            by_ref: HashMap::new(),
            names: HashMap::new(),
            link_names: HashMap::new(),
            incoming: HashMap::new(),
            index: search::Inverted::default(),
        }
    }

    pub fn encoding(&self) -> OffsetEncoding {
        self.encoding
    }

    /// Number of notes.
    pub fn len(&self) -> usize {
        self.by_ref.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_ref.is_empty()
    }

    // ----- roots ------------------------------------------------------------------------------

    /// Adds a root, last in the order. A root with this id is given the new path and keeps its
    /// place and its notes.
    pub fn add_root(&mut self, id: &str, path: &str) {
        match self.roots.iter_mut().find(|r| r.id == id) {
            Some(r) => r.path = path.to_owned(),
            None => self.roots.push(Root { id: id.to_owned(), path: path.to_owned() }),
        }
    }

    /// Removes a root and all its notes. False if there is no such root.
    pub fn remove_root(&mut self, id: &str) -> bool {
        let Some(at) = self.roots.iter().position(|r| r.id == id) else { return false };
        let doomed: Vec<NoteRef> = self.by_ref.keys().filter(|r| r.root == id).cloned().collect();
        for r in doomed {
            self.remove(&r);
        }
        self.roots.remove(at);
        true
    }

    /// The roots, in order.
    pub fn roots(&self) -> Vec<Root> {
        self.roots.clone()
    }

    fn root_rank(&self, id: &str) -> usize {
        self.roots.iter().position(|r| r.id == id).unwrap_or(usize::MAX)
    }

    // ----- feeding ----------------------------------------------------------------------------

    /// Indexes `text` as the note, replacing what was there. The links that name the note are
    /// resolved again; no other note is touched.
    pub fn upsert(&mut self, note: &NoteRef, text: &str, modified: i64) -> Result<(), LibraryError> {
        if !self.roots.iter().any(|r| r.id == note.root) {
            return Err(LibraryError::UnknownRoot);
        }
        let parsed = parse(text);
        self.insert(note, text.to_owned(), modified, parsed, true);
        Ok(())
    }

    /// Indexes many notes: parsing runs on all cores, the graph is resolved once at the end.
    /// Meant for start-up. Fails before changing anything if a root is unknown.
    pub fn upsert_all(&mut self, items: Vec<NoteInput>) -> Result<(), LibraryError> {
        if items.iter().any(|i| !self.roots.iter().any(|r| r.id == i.note.root)) {
            return Err(LibraryError::UnknownRoot);
        }
        let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(16);
        let chunk = items.len().div_ceil(threads).max(1);
        let parsed: Vec<Parsed> = if items.len() < 2 * threads {
            items.iter().map(|i| parse(&i.text)).collect()
        } else {
            std::thread::scope(|s| {
                let handles: Vec<_> =
                    items.chunks(chunk).map(|c| s.spawn(move || c.iter().map(|i| parse(&i.text)).collect::<Vec<_>>())).collect();
                handles.into_iter().flat_map(|h| h.join().expect("indexing thread panicked")).collect()
            })
        };
        for (item, parsed) in items.into_iter().zip(parsed) {
            self.insert(&item.note, item.text, item.modified, parsed, false);
        }
        let slots: Vec<u32> = (0..self.notes.len() as u32).filter(|&s| self.notes[s as usize].is_some()).collect();
        for slot in slots {
            self.resolve_links(slot);
        }
        Ok(())
    }

    /// Takes a note out of the index. False if it was not there.
    pub fn remove(&mut self, note: &NoteRef) -> bool {
        let Some(&slot) = self.by_ref.get(note) else { return false };
        let names = self.detach(slot, true);
        self.notes[slot as usize] = None;
        self.free.push(slot);
        self.by_ref.remove(note);
        self.refresh_referrers(&names, slot);
        true
    }

    /// Moves a note to a new path (and maybe root), keeping its text. A note already at `new`
    /// is replaced. Links to the old name, if nothing else answers to it, dangle afterwards:
    /// [`Library::rename_targets`] says what to change.
    pub fn rename(&mut self, old: &NoteRef, new: &NoteRef) -> Result<(), LibraryError> {
        let Some(&slot) = self.by_ref.get(old) else { return Err(LibraryError::NoSuchNote) };
        if !self.roots.iter().any(|r| r.id == new.root) {
            return Err(LibraryError::UnknownRoot);
        }
        if old == new {
            return Ok(());
        }
        let (text, modified) = {
            let n = self.notes[slot as usize].as_ref().expect("slot of a known note");
            (n.text.clone(), n.modified)
        };
        self.remove(old);
        let parsed = parse(&text);
        self.insert(new, text, modified, parsed, true);
        Ok(())
    }

    fn insert(&mut self, r: &NoteRef, text: String, modified: i64, parsed: Parsed, resolve: bool) {
        let existing = self.by_ref.get(r).copied();
        let mut old_names: Vec<String> = Vec::new();
        let slot = match existing {
            Some(slot) => {
                old_names = self.detach(slot, false);
                slot
            }
            None => match self.free.pop() {
                Some(slot) => slot,
                None => {
                    self.notes.push(None);
                    (self.notes.len() - 1) as u32
                }
            },
        };
        let stem = stem_of(&r.path).to_owned();
        let Parsed { h1, front_tags, inline_tags, links, headings, words, terms, body_start } = parsed;
        let mut tags: Vec<String> = front_tags.iter().chain(&inline_tags).cloned().collect();
        tags.sort();
        tags.dedup();
        let mut names = vec![text::key(&stem)];
        let title_key = text::key(h1.as_deref().unwrap_or(&stem));
        if !names.contains(&title_key) {
            names.push(title_key);
        }
        let title_words = text::words_of(&format!("{} {}", h1.as_deref().unwrap_or(""), stem));
        let term_ids = self.index.add(slot, &terms, &title_words);
        let n_links = links.len();
        let note = Note {
            r: r.clone(),
            map: OffsetMap::new(&text, self.encoding),
            text,
            modified,
            stem,
            h1,
            front_tags,
            inline_tags,
            tags,
            links,
            resolved: vec![None; n_links],
            headings,
            words,
            body_start,
            term_ids,
            names,
        };
        for name in &note.names {
            self.names.entry(name.clone()).or_default().push(slot);
        }
        for l in &note.links {
            for name in link_names_of(&l.key) {
                self.link_names.entry(name.to_owned()).or_default().insert(slot);
            }
        }
        let names = note.names.clone();
        self.notes[slot as usize] = Some(note);
        self.by_ref.insert(r.clone(), slot);
        if resolve {
            // The notes that name this one may resolve differently now; if neither its names
            // nor (for a replaced note) its place changed, none does.
            let mut changed = names;
            if existing.is_some() {
                let mut a = changed.clone();
                let mut b = old_names.clone();
                a.sort();
                b.sort();
                if a == b {
                    changed.clear();
                } else {
                    changed.extend(old_names);
                }
            }
            self.refresh_referrers(&changed, slot);
            self.resolve_links(slot);
        }
    }

    /// Takes a note's entries out of every index but the slot itself. Returns its names.
    /// The links that point at it stay, unless `forget_incoming`.
    fn detach(&mut self, slot: u32, forget_incoming: bool) -> Vec<String> {
        let note = self.notes[slot as usize].take().expect("a slot of a known note");
        for name in &note.names {
            if let Some(v) = self.names.get_mut(name) {
                v.retain(|&s| s != slot);
                if v.is_empty() {
                    self.names.remove(name);
                }
            }
        }
        for l in &note.links {
            for name in link_names_of(&l.key) {
                if let Some(set) = self.link_names.get_mut(name) {
                    set.remove(&slot);
                    if set.is_empty() {
                        self.link_names.remove(name);
                    }
                }
            }
        }
        for to in note.resolved.iter().flatten() {
            if let Some(set) = self.incoming.get_mut(to) {
                set.remove(&slot);
            }
        }
        if forget_incoming {
            self.incoming.remove(&slot);
        }
        self.index.remove(slot, &note.term_ids);
        note.names
    }

    /// Resolves again the links, in notes other than `except`, that name any of `names`.
    fn refresh_referrers(&mut self, names: &[String], except: u32) {
        let mut slots: Vec<u32> = Vec::new();
        for name in names {
            if let Some(set) = self.link_names.get(name) {
                slots.extend(set.iter().copied().filter(|&s| s != except));
            }
        }
        slots.sort_unstable();
        slots.dedup();
        for s in slots {
            self.resolve_links(s);
        }
    }

    /// Resolves every link of the note in `slot` and patches the edges.
    fn resolve_links(&mut self, slot: u32) {
        let Some(note) = self.notes[slot as usize].as_ref() else { return };
        let from = note.r.clone();
        let resolved: Vec<Option<u32>> = note.links.iter().map(|l| self.resolve(&from, &l.key)).collect();
        let note = self.notes[slot as usize].as_mut().expect("checked above");
        let old = std::mem::replace(&mut note.resolved, resolved.clone());
        for to in old.into_iter().flatten().filter(|&t| t != slot) {
            if let Some(set) = self.incoming.get_mut(&to) {
                set.remove(&slot);
            }
        }
        for to in resolved.into_iter().flatten().filter(|&t| t != slot) {
            self.incoming.entry(to).or_default().insert(slot);
        }
    }

    /// The note a link with `key` written in `from` goes to.
    fn resolve(&self, from: &NoteRef, key: &str) -> Option<u32> {
        if key.is_empty() {
            return self.by_ref.get(from).copied();
        }
        let mut candidates: Vec<u32> = self.names.get(key).cloned().unwrap_or_default();
        if let Some(slash) = key.rfind('/')
            && slash + 1 < key.len()
        {
            // `folder/Note`: by the last part, the rest must end the path. Only names
            // `link_names_of` registers count: a link that `refresh_referrers` cannot find would
            // keep pointing at a note that is gone.
            for &s in self.names.get(&key[slash + 1..]).into_iter().flatten() {
                let Some(n) = self.notes[s as usize].as_ref() else { continue };
                let path = text::key(without_extension(&n.r.path));
                if (path == key || path.ends_with(&format!("/{key}"))) && !candidates.contains(&s) {
                    candidates.push(s);
                }
            }
        }
        let from_folder: Vec<&str> = folder_of(&from.path).split('/').filter(|c| !c.is_empty()).collect();
        candidates.into_iter().min_by_key(|&s| {
            let n = self.notes[s as usize].as_ref().expect("a named slot");
            let same_root = n.r.root == from.root;
            let folder: Vec<&str> = folder_of(&n.r.path).split('/').filter(|c| !c.is_empty()).collect();
            let shared = if same_root { from_folder.iter().zip(&folder).take_while(|(a, b)| a == b).count() } else { 0 };
            // The last ties go by the normalised path first, so which of two equal candidates wins does not depend
            // on the form their paths are spelled in.
            (!same_root, Reverse(shared), folder.len(), text::key(&n.stem) != key, self.root_rank(&n.r.root), text::key(&n.r.path), n.r.path.clone())
        })
    }

    // ----- questions --------------------------------------------------------------------------

    fn slot(&self, s: u32) -> &Note {
        self.notes[s as usize].as_ref().expect("a live slot")
    }

    fn live(&self) -> impl Iterator<Item = (u32, &Note)> {
        self.notes.iter().enumerate().filter_map(|(s, n)| n.as_ref().map(|n| (s as u32, n)))
    }

    fn info(&self, n: &Note) -> NoteInfo {
        NoteInfo { note: n.r.clone(), title: n.title().to_owned(), tags: n.tags.clone(), word_count: n.words, modified: n.modified }
    }

    fn range(&self, n: &Note, start: usize, end: usize) -> TextRange {
        let mut c = n.map.cursor(&n.text);
        let s = c.to(start);
        let e = c.to(end);
        TextRange::new(s as u32, e as u32)
    }

    /// Everything the index knows about a note.
    pub fn note(&self, note: &NoteRef) -> Option<NoteMeta> {
        let n = self.slot(*self.by_ref.get(note)?);
        Some(NoteMeta {
            info: self.info(n),
            front_tags: n.front_tags.clone(),
            inline_tags: n.inline_tags.clone(),
            headings: n
                .headings
                .iter()
                .map(|h| HeadingInfo { level: h.level, text: h.text.clone(), range: self.range(n, h.start, h.end) })
                .collect(),
            links: n
                .links
                .iter()
                .zip(&n.resolved)
                .map(|(l, r)| LinkInfo {
                    target: l.target.clone(),
                    label: l.label.clone(),
                    heading: l.heading.clone(),
                    range: self.range(n, l.start, l.end),
                    resolved: r.map(|s| self.slot(s).r.clone()),
                })
                .collect(),
        })
    }

    /// Every tag with the number of notes carrying exactly it, sorted by tag.
    pub fn tags(&self) -> Vec<TagCount> {
        let mut counts: HashMap<&str, u32> = HashMap::new();
        for (_, n) in self.live() {
            for t in &n.tags {
                *counts.entry(t).or_default() += 1;
            }
        }
        let mut v: Vec<TagCount> = counts.into_iter().map(|(t, c)| TagCount { tag: t.to_owned(), count: c }).collect();
        v.sort_by(|a, b| a.tag.cmp(&b.tag));
        v
    }

    /// The notes `filter` keeps, in `sort` order.
    pub fn notes(&self, filter: &Filter, sort: Sort) -> Vec<NoteInfo> {
        let wanted: Vec<String> = filter.tags.iter().map(|t| text::normalize_tag(t)).collect();
        let folder = filter.folder.as_deref().map(|f| f.trim_matches('/')).filter(|f| !f.is_empty());
        let by_text: Option<HashSet<u32>> =
            filter.text.as_deref().filter(|t| !t.trim().is_empty()).map(|t| self.matching(t).into_iter().map(|f| f.slot).collect());
        let mut v: Vec<&Note> = self
            .live()
            .filter(|(s, n)| {
                filter.root.as_ref().is_none_or(|r| *r == n.r.root)
                    && folder.is_none_or(|f| n.r.path.strip_prefix(f).is_some_and(|rest| rest.starts_with('/')))
                    && wanted.iter().all(|w| n.tags.iter().any(|t| t == w || t.strip_prefix(w.as_str()).is_some_and(|r| r.starts_with('/'))))
                    && by_text.as_ref().is_none_or(|set| set.contains(s))
            })
            .map(|(_, n)| n)
            .collect();
        let file_name = |n: &Note| n.r.path.rsplit('/').next().unwrap_or("").to_lowercase();
        match sort {
            Sort::NameAscending => v.sort_by_cached_key(|n| (file_name(n), n.r.clone())),
            Sort::NameDescending => v.sort_by_cached_key(|n| (Reverse(file_name(n)), n.r.clone())),
            Sort::ModifiedNewest => v.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| a.r.cmp(&b.r))),
            Sort::ModifiedOldest => v.sort_by(|a, b| a.modified.cmp(&b.modified).then_with(|| a.r.cmp(&b.r))),
        }
        v.into_iter().map(|n| self.info(n)).collect()
    }

    fn matching(&self, query: &str) -> Vec<search::Found> {
        self.index.query(&text::words_of(query), self.notes.len())
    }

    /// Notes with a word starting with each of the query's words, best first: title matches,
    /// then occurrences, then path. At most `limit`.
    pub fn search(&self, query: &str, limit: usize) -> Vec<Hit> {
        let words = text::words_of(query);
        let mut found = self.index.query(&words, self.notes.len());
        found.sort_by(|a, b| {
            let (na, nb) = (&self.slot(a.slot).r, &self.slot(b.slot).r);
            b.title_terms.cmp(&a.title_terms).then(b.tf.cmp(&a.tf)).then_with(|| na.cmp(nb))
        });
        found.truncate(limit);
        found
            .into_iter()
            .map(|f| {
                let n = self.slot(f.slot);
                let (snippet, highlights) = self.snippet(n, &words);
                Hit {
                    note: n.r.clone(),
                    title: n.title().to_owned(),
                    snippet,
                    highlights,
                    title_match: f.title_terms > 0,
                    occurrences: f.tf,
                }
            })
            .collect()
    }

    /// The line around the first match, cut to about 160 characters, with the matches in it.
    fn snippet(&self, n: &Note, words: &[String]) -> (String, Vec<TextRange>) {
        let text = &n.text;
        let mut first = None;
        text::for_each_word(text, |s, e, w| {
            if first.is_none() && words.iter().any(|q| w.starts_with(q.as_str())) {
                first = Some((s, e));
            }
        });
        let (ms, me) = first.unwrap_or_else(|| {
            // Only the title matched: the first line of the body.
            let mut at = n.body_start;
            for line in text[n.body_start..].split_inclusive('\n') {
                if !line.trim().is_empty() {
                    break;
                }
                at += line.len();
            }
            (at, at)
        });
        let b = text.as_bytes();
        let mut ls = ms;
        while ls > 0 && !matches!(b[ls - 1], b'\n' | b'\r') {
            ls -= 1;
        }
        let mut le = me;
        while le < b.len() && !matches!(b[le], b'\n' | b'\r') {
            le += 1;
        }
        // At most 160 characters, 50 of them before the match.
        let from = text[ls..ms].char_indices().rev().nth(49).map_or(ls, |(i, _)| ls + i);
        let to = text[from..le].char_indices().nth(160).map_or(le, |(i, _)| from + i);
        let slice = text[from..to].trim();
        let map = OffsetMap::new(slice, self.encoding);
        let mut cursor = map.cursor(slice);
        let mut highlights = Vec::new();
        text::for_each_word(slice, |s, e, w| {
            if words.iter().any(|q| w.starts_with(q.as_str())) {
                let (a, b) = (cursor.to(s), cursor.to(e));
                highlights.push(TextRange::new(a as u32, b as u32));
            }
        });
        (slice.to_owned(), highlights)
    }

    /// Fuzzy match of `query` (a subsequence, case-insensitive, blanks ignored) against titles
    /// and paths, best first. An empty query lists the most recently modified notes.
    pub fn quick_open(&self, query: &str, limit: usize) -> Vec<Match> {
        let q: Vec<char> = query.chars().filter(|c| !c.is_whitespace()).flat_map(|c| c.to_lowercase().next()).collect();
        if q.is_empty() {
            let mut all: Vec<&Note> = self.live().map(|(_, n)| n).collect();
            all.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| a.r.cmp(&b.r)));
            return all
                .into_iter()
                .take(limit)
                .map(|n| Match { note: n.r.clone(), title: n.title().to_owned(), score: 0, title_ranges: vec![], path_ranges: vec![] })
                .collect();
        }
        let mut out: Vec<Match> = Vec::new();
        for (_, n) in self.live() {
            let by_title = fuzzy::fuzzy(&q, n.title()).map(|(s, p)| (s + 20, p));
            let by_path = fuzzy::fuzzy(&q, &n.r.path);
            let (score, title_ranges, path_ranges) = match (by_title, by_path) {
                (None, None) => continue,
                (Some((s, p)), None) => (s, runs(&p, n.title(), self.encoding), vec![]),
                (None, Some((s, p))) => (s, vec![], runs(&p, &n.r.path, self.encoding)),
                (Some((ts, tp)), Some((ps, pp))) => {
                    if ts >= ps {
                        (ts, runs(&tp, n.title(), self.encoding), runs(&pp, &n.r.path, self.encoding))
                    } else {
                        (ps, vec![], runs(&pp, &n.r.path, self.encoding))
                    }
                }
            };
            out.push(Match { note: n.r.clone(), title: n.title().to_owned(), score, title_ranges, path_ranges });
        }
        out.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.title.cmp(&b.title)).then_with(|| a.note.cmp(&b.note)));
        out.truncate(limit);
        out
    }

    /// The note `[[target]]` in `from` goes to (the target as written; a `#heading` or
    /// `|label` after it is ignored), if any.
    pub fn resolve_wikilink(&self, from: &NoteRef, target: &str) -> Option<NoteRef> {
        let target = target.split('|').next().unwrap_or("");
        let target = target.split('#').next().unwrap_or("");
        let slot = self.resolve(from, &link_key(target))?;
        Some(self.slot(slot).r.clone())
    }

    /// The links to a note from other notes, with their context. A link a note makes to itself
    /// is not a backlink. Sorted by linking note, then position.
    pub fn backlinks(&self, note: &NoteRef) -> Vec<Backlink> {
        let Some(&slot) = self.by_ref.get(note) else { return Vec::new() };
        let mut from: Vec<u32> = self.incoming.get(&slot).map(|s| s.iter().copied().collect()).unwrap_or_default();
        from.sort_by_key(|&s| (self.root_rank(&self.slot(s).r.root), self.slot(s).r.path.clone()));
        let mut out = Vec::new();
        for s in from {
            let n = self.slot(s);
            for (l, r) in n.links.iter().zip(&n.resolved) {
                if *r == Some(slot) {
                    out.push(Backlink {
                        from: n.r.clone(),
                        from_title: n.title().to_owned(),
                        range: self.range(n, l.start, l.end),
                        context: text::context(&n.text, l.start, l.end, 240),
                    });
                }
            }
        }
        out
    }

    /// The edits that make every link naming `old_title` (or a file stem, written without its
    /// extension) name `new_title` instead: the link's target is replaced, a label and a
    /// heading stay. Sorted by note, then position.
    pub fn rename_targets(&self, old_title: &str, new_title: &str) -> Vec<Edit> {
        let old = link_key(old_title);
        if old.is_empty() || old == link_key(new_title) {
            return Vec::new();
        }
        let mut notes: Vec<&Note> = self.live().map(|(_, n)| n).filter(|n| n.links.iter().any(|l| l.key == old)).collect();
        notes.sort_by(|a, b| (self.root_rank(&a.r.root), &a.r.path).cmp(&(self.root_rank(&b.r.root), &b.r.path)));
        let mut out = Vec::new();
        for n in notes {
            for l in n.links.iter().filter(|l| l.key == old) {
                out.push(Edit { note: n.r.clone(), range: self.range(n, l.target_start, l.target_end), replacement: new_title.to_owned() });
            }
        }
        out
    }

    /// The edits that keep the links to `old` pointing at it once the shell moves its file to
    /// `new`; asked before [`Library::rename`]. Only links that resolve to `old` now and name it
    /// by its file stem change: `[[Stem]]` becomes `[[New Stem]]`, `[[folder/Stem]]` keeps its
    /// folder while the note stays in its folder and names the new path otherwise; a label and
    /// a heading stay. A link naming the note's H1 title stays (the title does not change), and
    /// unlike [`Library::rename_targets`] a link to another note of the same name is left alone.
    /// Sorted by note, then position.
    pub fn rename_edits(&self, old: &NoteRef, new: &NoteRef) -> Vec<Edit> {
        let Some(&slot) = self.by_ref.get(old) else { return Vec::new() };
        let note = self.slot(slot);
        let stem = text::key(&note.stem);
        let new_stem = stem_of(&new.path);
        let same_folder = folder_of(&old.path) == folder_of(&new.path);
        let mut from: Vec<u32> = self.incoming.get(&slot).map(|s| s.iter().copied().collect()).unwrap_or_default();
        from.push(slot); // its own links to itself
        from.sort_by_key(|&s| (self.root_rank(&self.slot(s).r.root), self.slot(s).r.path.clone()));
        from.dedup();
        let mut out = Vec::new();
        for s in from {
            let n = self.slot(s);
            for (l, _) in n.links.iter().zip(&n.resolved).filter(|(_, r)| **r == Some(slot)) {
                let replacement = match l.key.rfind('/') {
                    None if l.key == stem => new_stem.to_owned(),
                    Some(at) if l.key[at + 1..] == stem => {
                        if same_folder {
                            // The folder as written, the new stem.
                            let written = l.target.rfind('/').map_or("", |i| &l.target[..=i]);
                            format!("{written}{new_stem}")
                        } else {
                            without_extension(&new.path).to_owned()
                        }
                    }
                    _ => continue,
                };
                if replacement != l.target {
                    out.push(Edit { note: n.r.clone(), range: self.range(n, l.target_start, l.target_end), replacement });
                }
            }
        }
        out
    }
}

/// Matched character indices of `s` as runs of ranges in the encoding's unit.
fn runs(positions: &[usize], s: &str, enc: OffsetEncoding) -> Vec<TextRange> {
    let unit = |c: char| match enc {
        OffsetEncoding::Utf8 => c.len_utf8(),
        OffsetEncoding::Utf16 => c.len_utf16(),
        OffsetEncoding::Utf32 => 1,
    };
    let mut starts = Vec::with_capacity(s.chars().count() + 1);
    let mut u = 0usize;
    for c in s.chars() {
        starts.push(u);
        u += unit(c);
    }
    starts.push(u);
    let chars: Vec<char> = s.chars().collect();
    let mut out: Vec<TextRange> = Vec::new();
    for &p in positions {
        let (a, b) = (starts[p] as u32, (starts[p] + unit(chars[p])) as u32);
        match out.last_mut() {
            Some(last) if last.end == a => last.end = b,
            _ => out.push(TextRange::new(a, b)),
        }
    }
    out
}
