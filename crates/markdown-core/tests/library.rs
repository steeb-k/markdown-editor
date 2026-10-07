//! The library index against the fixture library in `fixtures/library` (two roots: `main`, the
//! library proper, and `work`), the property that incremental updates equal a rebuild, and the
//! performance figures (ignored by default, release only).
mod common;
use common::slice_units;
use markdown_core::library::*;
use markdown_core::*;
use proptest::prelude::*;
use std::collections::BTreeMap;
use std::path::Path;

const ENC: OffsetEncoding = OffsetEncoding::Utf16;

fn r(root: &str, path: &str) -> NoteRef {
    NoteRef::new(root, path)
}

fn walk(dir: &Path, rel: &str, out: &mut Vec<(String, String)>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap()).collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let name = e.file_name().to_string_lossy().into_owned();
        let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
        if e.path().is_dir() {
            walk(&e.path(), &path, out);
        } else if name.ends_with(".md") || name.ends_with(".txt") {
            out.push((path, std::fs::read_to_string(e.path()).unwrap()));
        }
    }
}

/// (note, text) of every fixture note.
fn fixture_notes() -> Vec<(NoteRef, String)> {
    let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/library");
    let mut v = Vec::new();
    for root in ["main", "work"] {
        let mut files = Vec::new();
        walk(&base.join(root), "", &mut files);
        v.extend(files.into_iter().map(|(p, t)| (r(root, &p), t)));
    }
    v
}

fn fixture_library() -> Library {
    let mut lib = Library::new(ENC);
    lib.add_root("main", "/notes");
    lib.add_root("work", "/work");
    let items = fixture_notes()
        .into_iter()
        .enumerate()
        .map(|(i, (note, text))| NoteInput { note, text, modified: 1000 + i as i64 })
        .collect();
    lib.upsert_all(items).unwrap();
    lib
}

fn text_of(note: &NoteRef) -> String {
    fixture_notes().into_iter().find(|(n, _)| n == note).unwrap().1
}

fn meta(lib: &Library, root: &str, path: &str) -> NoteMeta {
    lib.note(&r(root, path)).unwrap_or_else(|| panic!("{root}:{path} is not in the library"))
}

fn paths(v: &[NoteInfo]) -> Vec<String> {
    v.iter().map(|n| format!("{}:{}", n.note.root, n.note.path)).collect()
}

#[test]
fn library_is_send_and_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Library>();
}

#[test]
fn the_fixture_library_loads() {
    let lib = fixture_library();
    assert!(fixture_notes().len() >= 30);
    assert_eq!(lib.len(), fixture_notes().len());
    assert_eq!(lib.roots().iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["main", "work"]);
    assert_eq!(lib.roots()[0].path, "/notes");
    let all = lib.notes(&Filter::default(), Sort::NameAscending);
    assert_eq!(all.len(), lib.len());
    let in_work = lib.notes(&Filter { root: Some("work".into()), ..Default::default() }, Sort::NameAscending);
    assert_eq!(paths(&in_work), ["work:Projects/Alpha.md", "work:Notes.md", "work:Standup.md"]);
    let deep = lib.notes(&Filter { folder: Some("Deep".into()), ..Default::default() }, Sort::NameAscending);
    assert_eq!(paths(&deep), ["main:Deep/Nested/Folders/Deep Note.md", "main:Deep/Folders.md"]);
    // A folder is a path prefix on a boundary: `Notes` is the folder, not the `Notes.md` file.
    let notes_dir = lib.notes(&Filter { folder: Some("Notes".into()), ..Default::default() }, Sort::NameAscending);
    assert_eq!(paths(&notes_dir), ["main:Notes/Ideas.md"]);
}

#[test]
fn titles_come_from_the_first_h1_else_the_file_stem() {
    let lib = fixture_library();
    let title = |root: &str, path: &str| meta(&lib, root, path).info.title;
    assert_eq!(title("main", "Projects/Alpha.md"), "Alpha Project");
    assert_eq!(title("main", "meeting-2026-10.md"), "Quarterly Meeting");
    assert_eq!(title("main", "plain.txt"), "plain");
    assert_eq!(title("main", "emoji party.md"), "\u{1F389} Party");
    assert_eq!(title("main", "Headings.md"), "Headings");
    assert_eq!(title("main", "Tagged In Heading.md"), "Tagged #heading");
    assert_eq!(title("main", "日本語のノート.md"), "日本語のノート");
    assert_eq!(title("main", "Ελληνικά.md"), "Ελληνικά");
}

#[test]
fn headings_without_their_markup_and_word_counts() {
    let lib = fixture_library();
    let m = meta(&lib, "main", "Headings.md");
    let h: Vec<(u8, &str)> = m.headings.iter().map(|h| (h.level, h.text.as_str())).collect();
    assert_eq!(
        h,
        [(1, "Headings"), (2, "Second level"), (3, "Third with code"), (1, "Setext heading"), (1, "Another top level")]
    );
    // The range is the whole heading in the note's text.
    let text = text_of(&r("main", "Headings.md"));
    assert_eq!(slice_units(&text, ENC, m.headings[1].range), "## Second *level*");
    // Front matter does not count as words.
    let alpha = meta(&lib, "main", "Projects/Alpha.md");
    let body = "# Alpha Project\n\nThe first project. Related: [[Beta]], [[Notes]] and [[Notes/Ideas|ideas]].\n\n## Goals\n\nShip the library. See [[Alpha#Goals]] and [[Gamma|the third one]].\n\n#project/alpha\n";
    let words = body.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).count();
    assert_eq!(alpha.info.word_count as usize, words);
    assert_eq!(meta(&lib, "main", "plain.txt").info.word_count, 11);
}

#[test]
fn tags_in_front_matter_in_each_form_and_inline() {
    let lib = fixture_library();
    // A flow list, a comma string, a block list (quotes and a `#` stripped, case folded).
    assert_eq!(meta(&lib, "main", "Projects/Alpha.md").front_tags, ["active", "project"]);
    assert_eq!(meta(&lib, "main", "Projects/Beta.md").front_tags, ["archived", "project"]);
    assert_eq!(meta(&lib, "main", "Projects/Gamma.md").front_tags, ["idea", "later", "project"]);
    assert_eq!(meta(&lib, "main", "Projects/Alpha.md").inline_tags, ["project/alpha"]);
    assert_eq!(meta(&lib, "main", "Projects/Alpha.md").info.tags, ["active", "project", "project/alpha"]);
    assert_eq!(meta(&lib, "main", "Templates/Daily.md").front_tags, ["daily"]);

    let tags = lib.tags();
    let count = |t: &str| tags.iter().find(|c| c.tag == t).map_or(0, |c| c.count);
    assert_eq!(count("project"), 3);
    assert_eq!(count("daily"), 4); // three journal notes and the template
    assert_eq!(count("todo"), 2); // Ideas, Journal 10-03
    assert_eq!(count("todo/urgent"), 1);
    assert_eq!(count("meeting"), 2);
    assert_eq!(count("work"), 2);
    assert_eq!(count("日本語"), 1);
    assert!(tags.windows(2).all(|w| w[0].tag < w[1].tag), "sorted");
    assert!(tags.iter().all(|c| !c.tag.starts_with('#') && c.tag == c.tag.to_lowercase()));
}

#[test]
fn odd_front_matter_tags() {
    let mut lib = Library::new(ENC);
    lib.add_root("a", "/a");
    let front = |lib: &mut Library, yaml: &str| {
        lib.upsert(&r("a", "n.md"), &format!("---\n{yaml}\n---\nbody"), 0).unwrap();
        lib.note(&r("a", "n.md")).unwrap().front_tags
    };
    assert_eq!(front(&mut lib, "tags: \"a, b\""), ["a", "b"]);
    assert_eq!(front(&mut lib, "tags: [a,\n  b, \"c d\"]"), ["a", "b", "c d"]);
    assert_eq!(front(&mut lib, "tags:\n  - one\n  - 'two'\n  -three"), ["one", "two"]);
    assert_eq!(front(&mut lib, "tag: single"), ["single"]);
    assert_eq!(front(&mut lib, "Tags: X"), ["x"]);
    assert_eq!(front(&mut lib, "tags: [\"#a\", '#B/c']"), ["a", "b/c"]);
    // Empty, YAML's nulls, a comment, a block scalar: no tags (not a tag called `~` or `>`).
    for yaml in ["tags:", "tags: []", "tags: ~", "tags: null", "tags: Null", "tags: #a", "tags: >\n  a b", "tags: |\n  a", "tags: [~]"] {
        assert!(front(&mut lib, yaml).is_empty(), "{yaml:?}: {:?}", front(&mut lib, yaml));
    }
    assert!(lib.tags().is_empty());
}

#[test]
fn inline_tag_rules() {
    let lib = fixture_library();
    // Not after a letter, a digit, `&` or a backslash; a letter must follow; trailing `-` is not
    // part of it; `#a/b` nests.
    assert_eq!(meta(&lib, "main", "Escapes.md").inline_tags, ["nested/tag", "paren", "real", "trail"]);
    // Never in code, links or on a heading line.
    assert_eq!(meta(&lib, "main", "Snippets.md").inline_tags, ["real-tag"]);
    assert_eq!(meta(&lib, "main", "Tagged In Heading.md").inline_tags, ["body-tag"]);
    assert_eq!(meta(&lib, "main", "Headings.md").inline_tags, ["notaheadingtag", "tagged"]);
}

#[test]
fn tag_filters_take_all_tags_and_sub_tags() {
    let lib = fixture_library();
    let f = |tags: &[&str]| {
        paths(&lib.notes(&Filter { tags: tags.iter().map(|s| s.to_string()).collect(), ..Default::default() }, Sort::NameAscending))
    };
    assert_eq!(f(&["project", "active"]), ["main:Projects/Alpha.md"]);
    assert_eq!(f(&["#Project", "archived"]), ["main:Projects/Beta.md"]);
    // `todo` includes `todo/urgent`.
    assert_eq!(f(&["todo"]), ["main:Journal/2026-10-03.md", "main:Notes/Ideas.md", "main:Inbox.md"]);
    assert_eq!(f(&["todo/urgent"]), ["main:Inbox.md"]);
    assert!(f(&["project", "daily"]).is_empty());
    assert!(f(&["nonexistent"]).is_empty());
    // With free text and a root.
    let both = lib.notes(
        &Filter { tags: vec!["meeting".into()], root: Some("work".into()), text: Some("standup".into()), ..Default::default() },
        Sort::NameAscending,
    );
    assert_eq!(paths(&both), ["work:Standup.md"]);
}

#[test]
fn sorting_by_name_and_by_modified_time() {
    let lib = fixture_library();
    let folder = Filter { folder: Some("Journal".into()), ..Default::default() };
    let n: Vec<String> = lib.notes(&folder, Sort::NameAscending).iter().map(|n| n.title.clone()).collect();
    assert_eq!(n, ["2026-10-01", "2026-10-02", "2026-10-03"]);
    let n: Vec<String> = lib.notes(&folder, Sort::NameDescending).iter().map(|n| n.title.clone()).collect();
    assert_eq!(n, ["2026-10-03", "2026-10-02", "2026-10-01"]);
    let newest = lib.notes(&Filter::default(), Sort::ModifiedNewest);
    assert!(newest.windows(2).all(|w| w[0].modified >= w[1].modified));
    let oldest = lib.notes(&Filter::default(), Sort::ModifiedOldest);
    assert!(oldest.windows(2).all(|w| w[0].modified <= w[1].modified));
    assert_eq!(newest.first().unwrap().note, oldest.last().unwrap().note);
    // Names sort by file name, case-folded, whatever the folder: `Alpha` before `Beta`.
    let projects = Filter { folder: Some("Projects".into()), root: Some("main".into()), ..Default::default() };
    let n: Vec<String> = lib.notes(&projects, Sort::NameAscending).iter().map(|n| n.note.path.clone()).collect();
    assert_eq!(n, ["Projects/Alpha.md", "Projects/Beta.md", "Projects/Gamma.md", "Projects/Notes.md"]);
}

/// Where each link of a note resolves to (`root:path`), in order.
fn link_view(lib: &Library, root: &str, path: &str) -> Vec<Option<String>> {
    meta(lib, root, path).links.iter().map(|l| l.resolved.as_ref().map(|n| format!("{}:{}", n.root, n.path))).collect()
}

#[test]
fn wikilinks_have_target_label_heading_and_range() {
    let lib = fixture_library();
    let m = meta(&lib, "main", "Projects/Alpha.md");
    let text = text_of(&r("main", "Projects/Alpha.md"));
    let shown: Vec<(&str, Option<&str>, Option<&str>, String)> = m
        .links
        .iter()
        .map(|l| (l.target.as_str(), l.label.as_deref(), l.heading.as_deref(), slice_units(&text, ENC, l.range)))
        .collect();
    assert_eq!(
        shown,
        [
            ("Beta", None, None, "[[Beta]]".to_owned()),
            ("Notes", None, None, "[[Notes]]".to_owned()),
            ("Notes/Ideas", Some("ideas"), None, "[[Notes/Ideas|ideas]]".to_owned()),
            ("Alpha", None, Some("Goals"), "[[Alpha#Goals]]".to_owned()),
            ("Gamma", Some("the third one"), None, "[[Gamma|the third one]]".to_owned()),
        ]
    );
    // None inside code, code blocks, escapes and the like.
    assert_eq!(link_view(&lib, "main", "Snippets.md").len(), 1);
    assert!(link_view(&lib, "main", "Escapes.md").is_empty());
}

#[test]
fn ranges_are_in_the_encoding_of_the_library() {
    // A note with an emoji and a combining accent before the link: the unit differs per encoding.
    let text = "\u{1F389} e\u{301} [[Target]]";
    for (enc, expected) in [(OffsetEncoding::Utf8, (9, 19)), (OffsetEncoding::Utf16, (6, 16)), (OffsetEncoding::Utf32, (5, 15))] {
        let mut lib = Library::new(enc);
        lib.add_root("a", "/a");
        lib.upsert(&r("a", "x.md"), text, 0).unwrap();
        let l = &lib.note(&r("a", "x.md")).unwrap().links[0];
        assert_eq!((l.range.start, l.range.end), expected, "{enc:?}");
    }
}

#[test]
fn wikilinks_resolve_by_title_or_stem_nearest_folder_first() {
    let lib = fixture_library();
    let v = |root: &str, path: &str| link_view(&lib, root, path);
    // Home: by stem with a path, by stem, by unicode title, by date stem, dangling.
    assert_eq!(
        v("main", "Home.md"),
        [
            Some("main:Projects/Alpha.md".to_owned()),
            Some("main:Inbox.md".to_owned()),
            Some("main:Notes.md".to_owned()),
            Some("main:Café Society.md".to_owned()),
            Some("main:日本語のノート.md".to_owned()),
            Some("main:Journal/2026-10-01.md".to_owned()),
            None,
        ]
    );
    // Duplicate stems in different folders: the nearest wins.
    let notes_from = |root: &str, path: &str| lib.resolve_wikilink(&r(root, path), "Notes").map(|n| format!("{}:{}", n.root, n.path));
    assert_eq!(notes_from("main", "Home.md").as_deref(), Some("main:Notes.md"));
    assert_eq!(notes_from("main", "Projects/Alpha.md").as_deref(), Some("main:Projects/Notes.md"));
    assert_eq!(notes_from("main", "Archive/Old Plan.md").as_deref(), Some("main:Archive/Notes.md"));
    assert_eq!(notes_from("main", "Deep/Nested/Folders/Deep Note.md").as_deref(), Some("main:Notes.md"));
    assert_eq!(notes_from("work", "Standup.md").as_deref(), Some("work:Notes.md"));
    // The same root before the other.
    assert_eq!(lib.resolve_wikilink(&r("main", "Inbox.md"), "Alpha"), Some(r("main", "Projects/Alpha.md")));
    assert_eq!(lib.resolve_wikilink(&r("work", "Standup.md"), "Alpha"), Some(r("work", "Projects/Alpha.md")));
    assert_eq!(lib.resolve_wikilink(&r("work", "Standup.md"), "Home"), Some(r("main", "Home.md")));
    // By title (the file is meeting-2026-10.md), case-insensitively, with an extension, with a
    // heading or a label after it, and as a path suffix.
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "quarterly meeting"), Some(r("main", "meeting-2026-10.md")));
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "Alpha.md"), Some(r("main", "Projects/Alpha.md")));
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "ALPHA#Goals"), Some(r("main", "Projects/Alpha.md")));
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "Archive/Notes"), Some(r("main", "Archive/Notes.md")));
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "Nested/Folders/Deep Note"), Some(r("main", "Deep/Nested/Folders/Deep Note.md")));
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "plain"), Some(r("main", "plain.txt")));
    // Dangling: nothing.
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "Missing Note"), None);
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), ""), Some(r("main", "Home.md")));
    // The dangling ones as the index sees them.
    assert_eq!(v("main", "Inbox.md").iter().filter(|x| x.is_none()).count(), 1);
}

/// A library of one root `main` with these notes, titled by their file stem.
fn lib_of(notes: &[(&str, &str)]) -> Library {
    let mut lib = Library::new(ENC);
    lib.add_root("main", "/notes");
    for (i, (path, text)) in notes.iter().enumerate() {
        lib.upsert(&r("main", path), text, i as i64).unwrap();
    }
    lib
}

#[test]
fn wikilinks_resolve_across_unicode_normalisation() {
    let nfc = "Caf\u{e9}";
    let nfd = "Cafe\u{301}";
    // A file name in one form, a link in the other, both ways round; the note keeps the path it was given.
    let lib = lib_of(&[
        (&format!("{nfd}.md"), "# Cafe\n"),
        (&format!("{nfc}.md"), "x"),
        ("From.md", &format!("[[{nfc}]] and [[{nfd}]]\n")),
    ]);
    // (The two spellings are one name, so the library holds two notes called the same; one wins, both ways round.)
    let target = lib.resolve_wikilink(&r("main", "From.md"), nfc).unwrap();
    assert_eq!(
        lib.resolve_wikilink(&r("main", "From.md"), nfd),
        Some(target.clone())
    );

    let a = lib_of(&[
        (&format!("{nfd}.md"), "text"),
        ("From.md", &format!("see [[{nfc}]]\n")),
    ]);
    assert_eq!(
        a.resolve_wikilink(&r("main", "From.md"), nfc),
        Some(r("main", &format!("{nfd}.md")))
    );
    assert_eq!(
        link_view(&a, "main", "From.md"),
        [Some(format!("main:{nfd}.md"))]
    );
    let b = lib_of(&[
        (&format!("{nfc}.md"), "text"),
        ("From.md", &format!("see [[{nfd}]]\n")),
    ]);
    assert_eq!(
        b.resolve_wikilink(&r("main", "From.md"), nfd),
        Some(r("main", &format!("{nfc}.md")))
    );
    assert_eq!(
        link_view(&b, "main", "From.md"),
        [Some(format!("main:{nfc}.md"))]
    );
    // The backlinks agree, and the text shown is the link as written.
    for (lib, path) in [(&a, format!("{nfd}.md")), (&b, format!("{nfc}.md"))] {
        let back = lib.backlinks(&r("main", &path));
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].from, r("main", "From.md"));
        assert!(back[0].context.contains("see [["));
    }
    // A title in one form, a link in the other, and a case difference on top.
    let t = lib_of(&[
        ("n.md", &format!("# {nfd}\n")),
        ("From.md", &format!("[[{}]]", nfc.to_uppercase())),
    ]);
    assert_eq!(
        link_view(&t, "main", "From.md"),
        [Some("main:n.md".to_owned())]
    );
    // Editing a note in place, to the other form, relinks what names it.
    let mut e = lib_of(&[("n.md", "# Plain\n"), ("From.md", &format!("[[{nfc}]]"))]);
    assert_eq!(link_view(&e, "main", "From.md"), [None]);
    e.upsert(&r("main", "n.md"), &format!("# {nfd}\n"), 5)
        .unwrap();
    assert_eq!(
        link_view(&e, "main", "From.md"),
        [Some("main:n.md".to_owned())]
    );
}

#[test]
fn a_folder_and_note_link_resolves_across_unicode_normalisation() {
    let (nfc, nfd) = ("Ren\u{e9}e", "Rene\u{301}e");
    let lib = lib_of(&[
        (&format!("{nfd}/Plan.md"), "x"),
        ("Other/Plan.md", "y"),
        ("From.md", &format!("[[{nfc}/Plan]]")),
    ]);
    assert_eq!(
        link_view(&lib, "main", "From.md"),
        [Some(format!("main:{nfd}/Plan.md"))]
    );
    let lib = lib_of(&[
        (&format!("{nfc}/Plan.md"), "x"),
        ("Other/Plan.md", "y"),
        ("From.md", &format!("[[{nfd}/Plan]]")),
    ]);
    assert_eq!(
        link_view(&lib, "main", "From.md"),
        [Some(format!("main:{nfc}/Plan.md"))]
    );
    // Moving the note to a folder in the other form keeps the link: the referrers are found by the same keys.
    let mut lib = lib_of(&[
        ("Plan.md", "x"),
        ("a/Plan.md", "z"),
        ("From.md", &format!("[[{nfd}/Plan]]")),
    ]);
    assert_eq!(link_view(&lib, "main", "From.md"), [None]);
    lib.upsert(&r("main", &format!("{nfc}/Plan.md")), "w", 9)
        .unwrap();
    assert_eq!(
        link_view(&lib, "main", "From.md"),
        [Some(format!("main:{nfc}/Plan.md"))]
    );
}

#[test]
fn tags_and_search_terms_are_one_across_unicode_normalisation() {
    let lib = lib_of(&[
        ("a.md", "#caf\u{e9} one\n"),
        ("b.md", "#cafe\u{301} two\n"),
        ("c.md", "---\ntags: [Cafe\u{301}]\n---\nz\n"),
    ]);
    let tags = lib.tags();
    assert_eq!(tags.len(), 1, "{tags:?}");
    assert_eq!(tags[0].count, 3);
    assert_eq!(tags[0].tag, "caf\u{e9}");
    let filter = Filter {
        tags: vec!["cafe\u{301}".to_owned()],
        ..Filter::default()
    };
    assert_eq!(lib.notes(&filter, Sort::NameAscending).len(), 3);
    // Words are found in the other form, and highlighted in the text as it is.
    let lib = lib_of(&[
        ("a.md", "a caf\u{e9} au lait\n"),
        ("b.md", "a cafe\u{301} noir\n"),
    ]);
    assert_eq!(lib.search("cafe\u{301}", 10).len(), 2);
    assert_eq!(lib.search("CAF\u{c9}", 10).len(), 2);
}

#[test]
fn a_note_that_links_to_itself_resolves_to_itself_and_is_not_its_own_backlink() {
    let lib = fixture_library();
    let v = link_view(&lib, "main", "Self.md");
    assert_eq!(v, vec![Some("main:Self.md".to_owned()); 3]);
    assert!(lib.backlinks(&r("main", "Self.md")).is_empty());
}

#[test]
fn backlinks_with_range_and_context() {
    let lib = fixture_library();
    let b = lib.backlinks(&r("main", "Projects/Alpha.md"));
    let from: Vec<(&str, &str)> = b.iter().map(|b| (b.from.path.as_str(), b.from_title.as_str())).collect();
    assert_eq!(
        from,
        [
            ("Archive/Old Plan.md", "Old Plan"),
            ("Home.md", "Home"),
            ("Inbox.md", "Inbox"),
            ("Inbox.md", "Inbox"),
            ("Journal/2026-10-01.md", "2026-10-01"),
            ("Projects/Beta.md", "Beta"),
            ("Projects/Notes.md", "Project Notes"),
            ("Snippets.md", "Snippets"),
        ]
    );
    // The note's own [[Alpha#Goals]] is not among them, and work's Alpha is another note.
    assert!(b.iter().all(|b| b.from.root == "main" && b.from.path != "Projects/Alpha.md"));
    for bl in &b {
        let text = text_of(&bl.from);
        let link = slice_units(&text, ENC, bl.range);
        assert!(link.starts_with("[[") && link.ends_with("]]"), "{link}");
        assert!(bl.context.contains(&link), "{:?} in {:?}", link, bl.context);
    }
    // The sentence around the link.
    let inbox: Vec<&Backlink> = b.iter().filter(|b| b.from.path == "Inbox.md").collect();
    assert_eq!(inbox[0].context, "Things to sort out: see [[Alpha]] and [[Alpha#Goals]].");
    let old = b.iter().find(|b| b.from.path == "Archive/Old Plan.md").unwrap();
    assert_eq!(old.context, "An old plan that mentions [[Alpha]] and [[Beta]] by name. #archived");
    // A note nothing links to, and one that is not there.
    assert!(lib.backlinks(&r("main", "Templates/Daily.md")).is_empty());
    assert!(lib.backlinks(&r("main", "nope.md")).is_empty());
    // work's Alpha: from work's Standup.
    let w = lib.backlinks(&r("work", "Projects/Alpha.md"));
    assert_eq!(w.iter().map(|b| b.from.path.as_str()).collect::<Vec<_>>(), ["Standup.md"]);
}

#[test]
fn backlink_contexts_are_cut_around_the_link() {
    let long = format!("{} [[Target]] {}", "word ".repeat(120), "tail ".repeat(120));
    let mut lib = Library::new(ENC);
    lib.add_root("a", "/a");
    lib.upsert(&r("a", "Target.md"), "# Target", 0).unwrap();
    lib.upsert(&r("a", "src.md"), &long, 0).unwrap();
    let b = lib.backlinks(&r("a", "Target.md"));
    assert_eq!(b.len(), 1);
    assert!(b[0].context.contains("[[Target]]"));
    assert!(b[0].context.chars().count() <= 240, "{}", b[0].context.len());
}

#[test]
fn search_is_prefix_and_case_folded_with_title_matches_first() {
    let lib = fixture_library();
    let hits = |q: &str| lib.search(q, 50).into_iter().map(|h| format!("{}:{}", h.note.root, h.note.path)).collect::<Vec<_>>();
    // Term frequency: the note with the word twice first.
    assert_eq!(hits("zebra"), ["main:Notes.md", "work:Notes.md"]);
    assert_eq!(hits("ZEB"), ["main:Notes.md", "work:Notes.md"]);
    assert_eq!(hits("aardvark"), ["main:Projects/Gamma.md"]);
    // Unicode case folding and prefixes.
    assert_eq!(hits("CAFÉ")[0], "main:Café Society.md");
    assert!(hits("größe").contains(&"main:Überblick.md".to_owned()));
    assert!(hits("ÜBER").contains(&"main:Überblick.md".to_owned()));
    assert!(hits("καλημ").contains(&"main:Ελληνικά.md".to_owned()));
    // Ideographic characters are words of their own.
    assert!(hits("検索").contains(&"main:日本語のノート.md".to_owned()));
    assert!(hits("ノート").contains(&"main:日本語のノート.md".to_owned()));
    // AND of the words, in any order.
    assert_eq!(hits("goals alpha"), ["main:Projects/Alpha.md", "main:Inbox.md"]);
    assert!(hits("goals zebra").is_empty());
    assert!(hits("").is_empty());
    assert!(hits("   !!! ").is_empty());
    assert!(hits("qqqqzzzz").is_empty());
    // Title matches rank first: `alpha` in a title before `alpha` only in a body.
    let h = lib.search("alpha", 50);
    let first_body_only = h.iter().position(|h| !h.title_match).unwrap();
    assert!(h[..first_body_only].iter().all(|h| h.title_match));
    assert!(h[first_body_only..].iter().all(|h| !h.title_match));
    let titles: Vec<&str> = h[..first_body_only].iter().map(|h| h.title.as_str()).collect();
    assert_eq!(titles, ["Alpha Project", "Alpha (work)"]);
    // The limit.
    assert_eq!(lib.search("alpha", 3).len(), 3);
    assert!(lib.search("alpha", 0).is_empty());
}

#[test]
fn search_hits_carry_a_snippet_with_highlights() {
    let lib = fixture_library();
    let h = lib.search("aardvark", 5);
    assert_eq!(h.len(), 1);
    assert_eq!(h[0].snippet, "Gamma has not started. The word aardvark appears only here.");
    let marked: Vec<String> = h[0].highlights.iter().map(|r| slice_units(&h[0].snippet, ENC, *r)).collect();
    assert_eq!(marked, ["aardvark"]);
    assert_eq!(h[0].occurrences, 1);
    assert!(!h[0].title_match);
    // Highlights in UTF-16 units after an emoji.
    let h = lib.search("confetti", 5);
    assert_eq!(h[0].snippet, "Confetti \u{1F389} and a link to [[Home]].");
    assert_eq!(slice_units(&h[0].snippet, ENC, h[0].highlights[0]), "Confetti");
    let h = lib.search("home", 20);
    for hit in &h {
        for r in &hit.highlights {
            assert!(slice_units(&hit.snippet, ENC, *r).to_lowercase().starts_with("home"));
        }
    }
    // A title-only match still has a snippet (the first body line).
    let h = lib.search("quarterly", 5);
    assert_eq!(h[0].note.path, "meeting-2026-10.md");
    assert!(h[0].title_match);
    assert!(!h[0].snippet.is_empty());
    // A long line is cut around the match.
    let mut long = Library::new(ENC);
    long.add_root("a", "/a");
    long.upsert(&r("a", "l.md"), &format!("{} needle {}", "x ".repeat(300), "y ".repeat(300)), 0).unwrap();
    let h = long.search("needle", 1);
    assert!(h[0].snippet.chars().count() <= 160 && h[0].snippet.contains("needle"), "{}", h[0].snippet.len());
}

#[test]
fn quick_open_matches_subsequences_and_prefers_contiguous_runs() {
    let lib = fixture_library();
    let q = |s: &str| lib.quick_open(s, 10);
    let first = |s: &str| q(s).first().map(|m| format!("{}:{}", m.note.root, m.note.path));
    assert_eq!(first("homee"), None);
    assert_eq!(first("home").as_deref(), Some("main:Home.md"));
    // A subsequence of the title or of the path.
    assert!(q("dnfd").iter().any(|m| m.note.path.ends_with("Deep Note.md")), "path subsequence");
    assert!(q("prjal").iter().any(|m| m.note.path == "Projects/Alpha.md"));
    // Case does not matter.
    assert_eq!(first("QUARTERLY").as_deref(), Some("main:meeting-2026-10.md"));
    // Spaces in the query are ignored.
    assert!(q("old plan").iter().any(|m| m.note.path == "Archive/Old Plan.md"));
    // Ranges are in the library's units: the emoji is two units, the space one.
    let m = q("party");
    assert_eq!(m[0].note.path, "emoji party.md");
    assert!(m[0].title_ranges == vec![TextRange::new(3, 8)] || m[0].path_ranges == vec![TextRange::new(6, 11)], "{m:?}");
    // Contiguous runs beat scattered letters, word starts beat the middle of a word.
    let mut lib = Library::new(ENC);
    lib.add_root("a", "/a");
    for (p, t) in [("1.md", "# Meeting"), ("2.md", "# My elephant eats tea thing"), ("3.md", "# Some meeting"), ("4.md", "# Mxexexting")] {
        lib.upsert(&r("a", p), t, 0).unwrap();
    }
    let order: Vec<String> = lib.quick_open("meet", 10).into_iter().map(|m| m.note.path).collect();
    assert_eq!(&order[..2], ["1.md", "3.md"]);
    assert_eq!(order.len(), 4);
    assert_eq!(order[3], "4.md");
    // No query: the most recently modified first.
    let recent = fixture_library().quick_open("", 3);
    assert_eq!(recent.len(), 3);
    // The limit.
    assert_eq!(q("a").len(), 10);
}

#[test]
fn rename_targets_edit_every_link_that_names_the_old_title() {
    let lib = fixture_library();
    let edits = lib.rename_targets("Alpha", "Alpha Prime");
    assert!(!edits.is_empty());
    let mut by_note: BTreeMap<NoteRef, Vec<&Edit>> = BTreeMap::new();
    for e in &edits {
        by_note.entry(e.note.clone()).or_default().push(e);
        assert_eq!(e.replacement, "Alpha Prime");
        let text = text_of(&e.note);
        assert_eq!(slice_units(&text, ENC, e.range), "Alpha", "{:?}", e.note);
    }
    let notes: Vec<String> = by_note.keys().map(|n| format!("{}:{}", n.root, n.path)).collect();
    assert_eq!(
        notes,
        [
            "main:Archive/Old Plan.md",
            "main:Inbox.md",
            "main:Journal/2026-10-01.md",
            "main:Projects/Alpha.md", // its own [[Alpha#Goals]]
            "main:Projects/Beta.md",
            "main:Projects/Notes.md",
            "main:Snippets.md",
            "work:Standup.md",
        ]
    );
    assert_eq!(by_note[&r("main", "Inbox.md")].len(), 2);
    // Case-insensitive, extension ignored; nothing for an unused name or an unchanged one.
    assert_eq!(lib.rename_targets("alpha.md", "X").len(), edits.len());
    assert!(lib.rename_targets("Nothing Here", "X").is_empty());
    assert!(lib.rename_targets("Alpha", "alpha").is_empty());

    // Applying them and renaming the file leaves the links pointing at it.
    let mut lib = lib;
    let before = lib.backlinks(&r("main", "Projects/Alpha.md")).len();
    for (note, es) in &by_note {
        let mut text = text_of(note);
        let mut es = es.clone();
        es.sort_by_key(|e| std::cmp::Reverse(e.range.start));
        for e in es {
            let (s, t) = (utf16_to_byte(&text, e.range.start), utf16_to_byte(&text, e.range.end));
            text.replace_range(s..t, &e.replacement);
        }
        lib.upsert(note, &text, 5000).unwrap();
    }
    lib.rename(&r("main", "Projects/Alpha.md"), &r("main", "Projects/Alpha Prime.md")).unwrap();
    let after = lib.backlinks(&r("main", "Projects/Alpha Prime.md"));
    // Everything that linked to it still does, except the path-style link on Home that names the
    // old file ([[Projects/Alpha|...]], it falls through to work's Alpha); work's Standup, edited
    // too, now reaches it across roots. The note's own link to itself never counts.
    assert_eq!(after.len(), before, "{after:#?}");
    assert!(after.iter().all(|b| b.from.path != "Home.md"));
    assert!(after.iter().any(|b| b.from.root == "work" && b.from.path == "Standup.md"));
    // `Alpha` is now nothing in `main`: it falls through to the other root's note.
    assert_eq!(lib.resolve_wikilink(&r("main", "Inbox.md"), "Alpha"), Some(r("work", "Projects/Alpha.md")));
}

/// Applies `edits` (any order) to the fixture texts and upserts the notes they touch.
fn apply(lib: &mut Library, edits: &[Edit]) {
    let mut by_note: BTreeMap<NoteRef, Vec<&Edit>> = BTreeMap::new();
    for e in edits {
        by_note.entry(e.note.clone()).or_default().push(e);
    }
    for (note, mut es) in by_note {
        let mut text = text_of(&note);
        es.sort_by_key(|e| std::cmp::Reverse(e.range.start));
        for e in es {
            let (s, t) = (utf16_to_byte(&text, e.range.start), utf16_to_byte(&text, e.range.end));
            text.replace_range(s..t, &e.replacement);
        }
        lib.upsert(&note, &text, 7000).unwrap();
    }
}

#[test]
fn rename_edits_follow_the_links_that_resolve_to_the_note() {
    let mut lib = fixture_library();
    let (old, new) = (r("main", "Projects/Alpha.md"), r("main", "Projects/Alpha Prime.md"));
    let edits = lib.rename_edits(&old, &new);
    let view: Vec<(String, String, String)> = edits
        .iter()
        .map(|e| (format!("{}:{}", e.note.root, e.note.path), slice_units(&text_of(&e.note), ENC, e.range), e.replacement.clone()))
        .collect();
    let v = |n: &str, from: &str, to: &str| (n.to_owned(), from.to_owned(), to.to_owned());
    assert_eq!(
        view,
        [
            v("main:Archive/Old Plan.md", "Alpha", "Alpha Prime"),
            v("main:Home.md", "Projects/Alpha", "Projects/Alpha Prime"), // the folder as written
            v("main:Inbox.md", "Alpha", "Alpha Prime"),
            v("main:Inbox.md", "Alpha", "Alpha Prime"),
            v("main:Journal/2026-10-01.md", "Alpha", "Alpha Prime"),
            v("main:Projects/Alpha.md", "Alpha", "Alpha Prime"), // its own [[Alpha#Goals]]
            v("main:Projects/Beta.md", "Alpha", "Alpha Prime"),
            v("main:Projects/Notes.md", "Alpha", "Alpha Prime"),
            v("main:Snippets.md", "Alpha", "Alpha Prime"),
        ]
    );
    // work's Standup links to work's Alpha and is left alone (rename_targets would change it).
    assert!(lib.rename_targets("Alpha", "Alpha Prime").iter().any(|e| e.note.root == "work"));
    let before: Vec<NoteRef> = lib.backlinks(&old).into_iter().map(|b| b.from).collect();
    apply(&mut lib, &edits);
    lib.rename(&old, &new).unwrap();
    let after: Vec<NoteRef> = lib.backlinks(&new).into_iter().map(|b| b.from).collect();
    assert_eq!(after, before, "every link still reaches it, Home's path-style one too");
    assert_eq!(lib.resolve_wikilink(&r("work", "Standup.md"), "Alpha"), Some(r("work", "Projects/Alpha.md")));
    assert_eq!(meta(&lib, "main", "Projects/Alpha Prime.md").links.iter().find(|l| l.heading.as_deref() == Some("Goals")).unwrap().resolved, Some(new.clone()), "the self link");

    // Duplicate stems: only the links to this `Notes` change, not those to the others.
    let lib = fixture_library();
    let edits = lib.rename_edits(&r("main", "Projects/Notes.md"), &r("main", "Projects/Plans.md"));
    let notes: Vec<&str> = edits.iter().map(|e| e.note.path.as_str()).collect();
    assert_eq!(notes, ["Projects/Alpha.md", "Projects/Beta.md"]);
    assert!(edits.iter().all(|e| e.replacement == "Plans"));
    assert!(lib.rename_targets("Notes", "Plans").len() > edits.len());
    // A move to another folder: path-style links name the new path, the stem links stay.
    let edits = lib.rename_edits(&r("main", "Projects/Alpha.md"), &r("main", "Archive/Alpha.md"));
    assert_eq!(edits.len(), 1);
    assert_eq!((edits[0].note.path.as_str(), edits[0].replacement.as_str()), ("Home.md", "Archive/Alpha"));
    // A link by the H1 title stays, the title does not change; nothing for a note not there.
    let mut lib = fixture_library();
    lib.upsert(&r("main", "T.md"), "[[Alpha Project]] and [[alpha|x]]", 0).unwrap();
    let edits = lib.rename_edits(&r("main", "Projects/Alpha.md"), &r("main", "Projects/A2.md"));
    let in_t: Vec<&Edit> = edits.iter().filter(|e| e.note.path == "T.md").collect();
    assert_eq!(in_t.len(), 1);
    assert_eq!((in_t[0].range, in_t[0].replacement.as_str()), (TextRange::new(24, 29), "A2"));
    assert!(lib.rename_edits(&r("main", "nope.md"), &r("main", "x.md")).is_empty());
}

fn utf16_to_byte(text: &str, unit: u32) -> usize {
    let mut u = 0;
    for (i, c) in text.char_indices() {
        if u == unit {
            return i;
        }
        u += c.len_utf16() as u32;
    }
    text.len()
}

#[test]
fn templates_fill_placeholders_and_place_the_caret() {
    let text = text_of(&r("main", "Templates/Daily.md"));
    let vars: std::collections::HashMap<String, String> = [
        ("date", "2026-10-03"),
        ("time", "09:30"),
        ("title", "Saturday \u{1F389}"),
        ("today", "2026-10-03"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.to_owned()))
    .collect();
    let t = expand_template(&text, &vars, OffsetEncoding::Utf16);
    assert!(t.text.contains("# Saturday \u{1F389}\n"));
    assert!(t.text.contains("Date: 2026-10-03\nTime: 09:30\nToday: 2026-10-03\n"));
    assert!(t.text.contains("Unknown: {{nonsense}}"), "an unknown placeholder stays");
    assert!(!t.text.contains("{{cursor}}") && !t.text.contains("{{ cursor }}"));
    assert!(t.text.contains("Second  is dropped."));
    // The caret is where the first {{cursor}} stood, in UTF-16 units (the emoji counts two).
    let at = t.text.find("## Notes\n\n").unwrap() + "## Notes\n\n".len();
    let units = t.text[..at].encode_utf16().count() as u32;
    assert_eq!(t.cursor, units);
    assert_eq!(expand_template(&text, &vars, OffsetEncoding::Utf8).cursor as usize, at);
    assert_eq!(expand_template(&text, &vars, OffsetEncoding::Utf32).cursor as usize, t.text[..at].chars().count());
    // No cursor: the end. Names are case-insensitive and blanks are allowed. Stray braces are text.
    let t = expand_template("a {{ DATE }} {{ {{b}} {{", &vars, ENC);
    assert_eq!(t.text, "a 2026-10-03 {{ {{b}} {{");
    assert_eq!(t.cursor, t.text.encode_utf16().count() as u32);
    // A brace before a placeholder is text (`{{{date}}}` in a template for a templating language).
    assert_eq!(expand_template("{{{date}}} {{{{time}}}}", &vars, ENC).text, "{2026-10-03} {{09:30}}");
    // Values are not expanded again; a placeholder in code is still one (templates are text).
    let v: std::collections::HashMap<String, String> = [("x".to_owned(), "{{date}}".to_owned())].into();
    assert_eq!(expand_template("{{x}} `{{x}}`", &v, ENC).text, "{{date}} `{{date}}`");
    let c = expand_template("{{cursor}}a{{cursor}}b", &v, ENC);
    assert_eq!((c.text.as_str(), c.cursor), ("ab", 0));
    assert_eq!(expand_template("", &vars, ENC), Template { text: String::new(), cursor: 0 });
    // The Meeting template as shipped.
    let t = expand_template(&text_of(&r("main", "Templates/Meeting.md")), &vars, ENC);
    assert_eq!(t.text, "# Meeting 2026-10-03\n\nAttendees:\n\n\n");
    assert_eq!(t.cursor as usize, "# Meeting 2026-10-03\n\nAttendees:\n\n".len());
}

#[test]
fn incremental_updates_patch_the_graph() {
    let mut lib = fixture_library();
    let alpha = r("main", "Projects/Alpha.md");
    let n = lib.backlinks(&alpha).len();
    // A new note linking to Alpha, with a tag and a word.
    lib.upsert(&r("main", "New.md"), "# New\n\nSee [[Alpha]] #fresh pangolin", 9000).unwrap();
    assert_eq!(lib.backlinks(&alpha).len(), n + 1);
    assert_eq!(lib.search("pangolin", 5).len(), 1);
    assert_eq!(lib.tags().iter().find(|t| t.tag == "fresh").map(|t| t.count), Some(1));
    assert_eq!(lib.len(), fixture_notes().len() + 1);
    // Edited: the link goes, the word changes.
    lib.upsert(&r("main", "New.md"), "# New\n\nNo link now, #other okapi", 9001).unwrap();
    assert_eq!(lib.backlinks(&alpha).len(), n);
    assert!(lib.search("pangolin", 5).is_empty());
    assert_eq!(lib.search("okapi", 5).len(), 1);
    assert!(lib.tags().iter().all(|t| t.tag != "fresh"));
    // A dangling link starts to resolve when its target appears, and dangles again when it goes.
    let inbox = r("main", "Inbox.md");
    let dangling = |lib: &Library| meta(lib, "main", "Inbox.md").links.iter().filter(|l| l.resolved.is_none()).count();
    assert_eq!(dangling(&lib), 1);
    lib.upsert(&r("main", "Missing Note.md"), "# Whatever", 9002).unwrap();
    assert_eq!(dangling(&lib), 0);
    assert_eq!(lib.backlinks(&r("main", "Missing Note.md")).len(), 1);
    assert!(lib.remove(&r("main", "Missing Note.md")));
    assert!(!lib.remove(&r("main", "Missing Note.md")));
    assert_eq!(dangling(&lib), 1);
    assert!(lib.backlinks(&r("main", "Missing Note.md")).is_empty());
    // Nearer duplicate stems take over, and give way again.
    let beta_notes = |lib: &Library| meta(lib, "main", "Projects/Beta.md").links[0].resolved.clone();
    assert_eq!(beta_notes(&lib), Some(r("main", "Projects/Notes.md")));
    lib.remove(&r("main", "Projects/Notes.md"));
    assert_eq!(beta_notes(&lib), Some(r("main", "Notes.md")));
    lib.upsert(&r("main", "Projects/Notes.md"), "# Back", 9003).unwrap();
    assert_eq!(beta_notes(&lib), Some(r("main", "Projects/Notes.md")));
    // A title change moves what links resolve to: Back is no longer called "Notes" by stem, only.
    lib.upsert(&inbox, &text_of(&inbox), 9004).unwrap();
    // Rename.
    lib.rename(&r("main", "Journal/2026-10-01.md"), &r("main", "Journal/first.md")).unwrap();
    assert_eq!(lib.resolve_wikilink(&r("main", "Home.md"), "2026-10-01"), Some(r("main", "Journal/first.md")));
    assert_eq!(meta(&lib, "main", "Journal/first.md").info.title, "2026-10-01");
    assert_eq!(lib.rename(&r("main", "nope.md"), &r("main", "x.md")), Err(LibraryError::NoSuchNote));
    assert_eq!(lib.rename(&r("main", "Home.md"), &r("zzz", "x.md")), Err(LibraryError::UnknownRoot));
    assert_eq!(lib.upsert(&r("zzz", "x.md"), "x", 0), Err(LibraryError::UnknownRoot));
    // Renaming over another note replaces it.
    let count = lib.len();
    lib.rename(&r("main", "Journal/first.md"), &r("main", "Journal/2026-10-02.md")).unwrap();
    assert_eq!(lib.len(), count - 1);
    // Removing a root takes its notes.
    assert!(lib.remove_root("work"));
    assert!(!lib.remove_root("work"));
    assert!(lib.note(&r("work", "Notes.md")).is_none());
    assert_eq!(lib.resolve_wikilink(&r("main", "Inbox.md"), "Alpha"), Some(alpha.clone()));
    assert!(lib.search("zebra", 5).iter().all(|h| h.note.root == "main"));
    assert_eq!(lib.upsert(&r("work", "x.md"), "x", 0), Err(LibraryError::UnknownRoot));
}

#[test]
fn a_link_ending_in_a_slash_never_holds_on_to_a_removed_note() {
    // `[[/]]` and `[[x/]]` used to resolve by path to a note with an empty stem (`/`, `x/`), under
    // a name the graph did not index the link by: removing that note left the link pointing at
    // a freed slot, and the next question about it panicked.
    for (path, link) in [("/", "[[/]]"), ("x/", "[[x/]]")] {
        let mut lib = Library::new(ENC);
        lib.add_root("r", "/");
        lib.upsert(&r("r", path), "", 0).unwrap();
        lib.upsert(&r("r", "from.md"), link, 0).unwrap();
        lib.rename(&r("r", path), &r("r", "a.md")).unwrap();
        assert_eq!(meta(&lib, "r", "from.md").links[0].resolved, None, "{link}");
        assert!(lib.backlinks(&r("r", "a.md")).is_empty());
        lib.remove(&r("r", "a.md"));
        lib.upsert(&r("r", "b.md"), "x", 0).unwrap();
        assert_eq!(meta(&lib, "r", "from.md").links[0].resolved, None, "{link}");
    }
}

#[test]
fn a_library_behind_a_mutex_serves_several_threads() {
    use std::sync::{Arc, Mutex};
    let shared = Arc::new(Mutex::new((fixture_library(), BTreeMap::<NoteRef, (String, i64)>::new())));
    {
        let mut g = shared.lock().unwrap();
        let notes: Vec<(NoteRef, String)> = fixture_notes();
        for (i, (n, t)) in notes.into_iter().enumerate() {
            g.1.insert(n, (t, 1000 + i as i64));
        }
    }
    let threads: Vec<_> = (0..6u64)
        .map(|k| {
            let shared = Arc::clone(&shared);
            std::thread::spawn(move || {
                let mut x = k + 1;
                for step in 0..200i64 {
                    x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    let mut g = shared.lock().unwrap();
                    let (lib, model) = &mut *g;
                    let note = r(if x % 3 == 0 { "work" } else { "main" }, &format!("t{}/n{}.md", (x >> 8) % 3, (x >> 16) % 5));
                    match (x >> 24) % 4 {
                        0 => {
                            lib.remove(&note);
                            model.remove(&note);
                        }
                        1 => {
                            let _ = lib.search("alpha n1", 10);
                            let _ = lib.backlinks(&r("main", "Projects/Alpha.md"));
                            let _ = lib.quick_open("n1", 5);
                        }
                        _ => {
                            let text = format!("# N{step}\n[[Alpha]] [[n{}]] #t{k}", (x >> 32) % 5);
                            lib.upsert(&note, &text, step).unwrap();
                            model.insert(note, (text, step));
                        }
                    }
                }
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    let g = shared.lock().unwrap();
    assert_eq!(snapshot(&g.0), snapshot(&rebuilt(&g.1, &["main", "work"], true)));
}

// ----- incremental equals rebuilt -----------------------------------------------------------------

/// Everything the public API says, as one comparable string.
fn snapshot(lib: &Library) -> String {
    let mut out = String::new();
    for info in lib.notes(&Filter::default(), Sort::NameAscending) {
        out.push_str(&format!("{:?}\n", lib.note(&info.note).unwrap()));
        out.push_str(&format!("  backlinks {:?}\n", lib.backlinks(&info.note)));
    }
    out.push_str(&format!("tags {:?}\n", lib.tags()));
    for q in ["zeta", "a", "t", "alpha beta", "x"] {
        out.push_str(&format!("search {q} {:?}\n", lib.search(q, 100)));
        out.push_str(&format!("quick {q} {:?}\n", lib.quick_open(q, 100)));
    }
    for t in ["a", "b", "c", "alpha", "sub/c", "A#h"] {
        out.push_str(&format!("rename {t} {:?}\n", lib.rename_targets(t, "Renamed")));
    }
    out
}

fn rebuilt(model: &BTreeMap<NoteRef, (String, i64)>, roots: &[&str], bulk: bool) -> Library {
    let mut lib = Library::new(ENC);
    for id in roots {
        lib.add_root(id, "/x");
    }
    if bulk {
        lib.upsert_all(model.iter().map(|(n, (t, m))| NoteInput { note: n.clone(), text: t.clone(), modified: *m }).collect()).unwrap();
    } else {
        for (n, (t, m)) in model.iter().rev() {
            lib.upsert(n, t, *m).unwrap();
        }
    }
    lib
}

#[derive(Debug, Clone)]
enum Op {
    Upsert(usize, String),
    Remove(usize),
    Rename(usize, usize),
}

// `x/` and `/` have an empty stem; `[[x/]]` and `[[/]]` must not resolve to them through it.
const PATHS: [&str; 10] = ["a.md", "b.md", "x/a.md", "x/c.md", "x/y/b.md", "x/y/z/Sub.md", "c.txt", "d.md", "x/", "/"];
const ROOTS: [&str; 2] = ["r1", "r2"];

fn note_of(i: usize) -> NoteRef {
    r(ROOTS[(i / PATHS.len()) % 2], PATHS[i % PATHS.len()])
}

fn note_text() -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "[[a]] ", "[[b|x]] ", "[[x/]] ", "[[/]] ", "[[y/b]] ", "[[sub/c]] ", "[[x/a]] ", "[[#h]] ", "[[A#h]] ", "[[Title]] ", "[[zeta]] ", "#t1 ", "#t/u ", "# Title\n",
        "# a\n", "## h\n", "word ", "zeta ", "alpha ", "beta ", "\n", "\n\n", "---\ntags: [x, t1]\n---\n", "`[[a]]` ", "[l](u) ", "\u{e9}t\u{e9} ",
        "\u{65E5}\u{672C} ", "#", "[[", "]]", "| ",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..12).prop_map(|v| v.concat())
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0usize..20, note_text()).prop_map(|(i, t)| Op::Upsert(i, t)),
        2 => (0usize..20).prop_map(Op::Remove),
        2 => (0usize..20, 0usize..20).prop_map(|(a, b)| Op::Rename(a, b)),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).map_or(200, |n: u32| n / 3 + 1)
    ))]

    /// Any sequence of upsert, remove and rename leaves the graph, tags, search and quick open
    /// exactly as a library built from the final notes in one go, or one by one in another order.
    #[test]
    fn incremental_updates_equal_a_rebuild(ops in prop::collection::vec(op(), 1..30)) {
        let mut lib = Library::new(ENC);
        for id in ROOTS {
            lib.add_root(id, "/x");
        }
        let mut model: BTreeMap<NoteRef, (String, i64)> = BTreeMap::new();
        for (step, op) in ops.into_iter().enumerate() {
            let modified = step as i64;
            match op {
                Op::Upsert(i, text) => {
                    lib.upsert(&note_of(i), &text, modified).unwrap();
                    model.insert(note_of(i), (text, modified));
                }
                Op::Remove(i) => {
                    prop_assert_eq!(lib.remove(&note_of(i)), model.remove(&note_of(i)).is_some());
                }
                Op::Rename(a, b) => {
                    let (from, to) = (note_of(a), note_of(b));
                    match lib.rename(&from, &to) {
                        Ok(()) => {
                            let v = model.remove(&from).unwrap();
                            model.insert(to, v);
                        }
                        Err(e) => {
                            prop_assert_eq!(e, LibraryError::NoSuchNote);
                            prop_assert!(!model.contains_key(&from));
                        }
                    }
                }
            }
            prop_assert_eq!(lib.len(), model.len());
        }
        let live = snapshot(&lib);
        prop_assert_eq!(&live, &snapshot(&rebuilt(&model, &ROOTS, true)));
        prop_assert_eq!(&live, &snapshot(&rebuilt(&model, &ROOTS, false)));
    }
}

fn any_text() -> impl Strategy<Value = String> {
    const T: &[&str] = &[
        "[[", "]]", "|", "#", "#a", "a", "/", ".", " ", "\n", "\r\n", "---\n", "tags: ", "- ", "[", "]", "\u{301}", "\u{1F389}", "\u{65E5}", "`",
        "\\", "&", "{{", "}}", "cursor", "\t", "> ", "# ", "|---|\n", "<b>", "\u{130}", "\u{df}", "\0",
    ];
    prop_oneof![prop::collection::vec(prop::sample::select(T), 0..40).prop_map(|v| v.concat()), any::<String>()]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).map_or(300, |n: u32| n / 2 + 1)
    ))]

    /// Odd paths, odd text, odd queries: no question or change ever panics. (A panic in the
    /// middle of a change would leave the index half-patched behind the FFI's lock.)
    #[test]
    fn nothing_panics_on_any_input(
        notes in prop::collection::vec((prop::sample::select(vec!["", ".md", "/", "a", "A.MD", "x//a.md", "/a.md", "x/", "..", "\u{65E5}/\u{130}.md", "\u{1F389}.txt"]), any_text()), 1..8),
        q in any_text(), q2 in any_text(),
        ops in prop::collection::vec((0usize..8, 0usize..8, 0u8..3), 0..8),
    ) {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let mut lib = Library::new(enc);
            lib.add_root("r", "/");
            lib.add_root("s", "/");
            let refs: Vec<NoteRef> = notes.iter().enumerate().map(|(i, (p, _))| r(["r", "s"][i % 2], p)).collect();
            for (n, (_, t)) in refs.iter().zip(&notes) {
                lib.upsert(n, t, 0).unwrap();
            }
            for &(a, b, k) in &ops {
                let (a, b) = (&refs[a % refs.len()], &refs[b % refs.len()]);
                match k {
                    0 => { let _ = lib.rename(a, b); }
                    1 => { lib.remove(a); }
                    _ => { let _ = lib.upsert(a, &q2, 1); }
                }
            }
            let _ = (lib.search(&q, 10), lib.quick_open(&q, 10), lib.tags(), lib.rename_targets(&q, &q2));
            let _ = lib.notes(&Filter { root: None, folder: Some(q2.clone()), tags: vec![q.clone()], text: Some(q.clone()) }, Sort::NameAscending);
            for n in &refs {
                let _ = (lib.backlinks(n), lib.note(n), lib.resolve_wikilink(n, &q), lib.rename_edits(n, &refs[0]));
            }
            let _ = expand_template(&q, &[(q2.clone(), q.clone())].into(), enc);
            let doc = Document::new(&q, enc);
            for o in 0..=(q.len() as u32).min(64) {
                let _ = doc.wikilink_at(o);
            }
        }
        let _ = wiki::find_in(&q, 0, q.len(), &[], true);
    }
}

// ----- performance --------------------------------------------------------------------------------

/// Deterministic pseudo-random text of about `size` bytes: headings, paragraphs of words from a
/// vocabulary of `vocab` words, wikilinks to other notes, tags.
fn synthetic(seed: u64, size: usize, notes: usize, vocab: usize) -> String {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    let mut next = move || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let word = |n: u64| format!("w{}x{}", n % vocab as u64, (n % vocab as u64) % 7);
    let mut s = format!("# Note {seed} {}\n\n", word(next()));
    while s.len() < size {
        match next() % 12 {
            0 => s.push_str(&format!("\n## Section {}\n\n", word(next()))),
            1 => {
                let i = next() % notes as u64;
                s.push_str(&format!("[[Note {i} w{}x{}]] ", i % 997, i % 7));
            }
            2 => s.push_str(&format!("#tag{} ", next() % 200)),
            _ => {
                for _ in 0..8 {
                    s.push_str(&word(next()));
                    s.push(' ');
                }
                s.push_str("with *emphasis* and `code`.\n");
            }
        }
    }
    s
}

/// 5 000 notes, 50 MB: `cargo test --release -p markdown-core --test library -- --ignored --nocapture`.
#[test]
#[ignore]
fn five_thousand_notes_fifty_megabytes() {
    let n = 5000;
    let items: Vec<NoteInput> = (0..n)
        .map(|i| NoteInput {
            note: r("main", &format!("folder{}/sub{}/Note {i} w{}x{}.md", i % 20, i % 7, i % 997, i % 7)),
            text: synthetic(i as u64 + 1, 10_000, n, 5000),
            modified: i as i64,
        })
        .collect();
    let bytes: usize = items.iter().map(|i| i.text.len()).sum();
    println!("{} notes, {:.1} MB", items.len(), bytes as f64 / 1e6);

    let mut lib = Library::new(OffsetEncoding::Utf16);
    lib.add_root("main", "/notes");
    let t = std::time::Instant::now();
    lib.upsert_all(items.clone()).unwrap();
    let rebuild = t.elapsed().as_secs_f64() * 1e3;
    println!("rebuild: {rebuild:.0} ms");
    assert_eq!(lib.len(), n);
    // On one core (a small Linux machine): the same notes upserted one by one, each patching the
    // graph as it comes. Not asserted.
    let mut one = Library::new(OffsetEncoding::Utf16);
    one.add_root("main", "/notes");
    let t = std::time::Instant::now();
    for i in &items {
        one.upsert(&i.note, &i.text, i.modified).unwrap();
    }
    println!("rebuild on one thread, one upsert at a time: {:.0} ms", t.elapsed().as_secs_f64() * 1e3);
    drop(one);

    let mut times = Vec::new();
    for k in 0..30 {
        let i = (k * 163) % n;
        let t = std::time::Instant::now();
        lib.upsert(&items[i].note, &items[(i + 1) % n].text, 99_999).unwrap();
        times.push(t.elapsed().as_secs_f64() * 1e3);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let upsert = times[times.len() / 2];
    println!("upsert: median {upsert:.2} ms, worst {:.2} ms", times.last().unwrap());

    let mut worst: f64 = 0.0;
    for q in ["w1x1", "w", "w12", "note", "w1 w2", "w4999x3 section", "tag1", "emphasis code", "zzzz"] {
        let t = std::time::Instant::now();
        let hits = lib.search(q, 50);
        let ms = t.elapsed().as_secs_f64() * 1e3;
        println!("search {q:?}: {ms:.2} ms ({} hits)", hits.len());
        worst = worst.max(ms);
    }
    let t = std::time::Instant::now();
    let q = lib.quick_open("note 12 w", 20);
    println!("quick_open: {:.2} ms ({} matches)", t.elapsed().as_secs_f64() * 1e3, q.len());
    let t = std::time::Instant::now();
    let b = lib.backlinks(&items[17].note);
    assert!(!b.is_empty(), "the synthetic links resolve");
    println!("backlinks: {:.2} ms ({})", t.elapsed().as_secs_f64() * 1e3, b.len());
    let t = std::time::Instant::now();
    let tags = lib.tags();
    let listed = lib.notes(&Filter { tags: vec!["tag7".into()], ..Default::default() }, Sort::NameAscending);
    println!("tags + filter: {:.2} ms ({} tags, {} notes)", t.elapsed().as_secs_f64() * 1e3, tags.len(), listed.len());

    assert!(rebuild < 2000.0, "rebuild took {rebuild:.0} ms");
    assert!(upsert < 5.0, "upsert took {upsert:.2} ms");
    assert!(worst < 20.0, "search took {worst:.2} ms");
}

// ----- unlinked mentions ----------------------------------------------------------------------------

/// What the mentions of `target` in these notes say: (mentioning path, matched text), in the order given.
fn mention_view(notes: &[(&str, &str)], target: &str) -> Vec<(String, String)> {
    let lib = lib_of(notes);
    lib.mentions(&r("main", target))
        .into_iter()
        .map(|m| {
            let text = notes.iter().find(|(p, _)| *p == m.from.path).unwrap().1;
            (m.from.path.clone(), slice_units(text, ENC, m.range))
        })
        .collect()
}

fn pair(a: &str, b: &str) -> (String, String) {
    (a.to_owned(), b.to_owned())
}

#[test]
fn aliases_are_read_from_front_matter_in_each_list_form() {
    let lib = lib_of(&[
        ("A.md", "---\naliases: [Alpha, \"The A\", 'Aye']\n---\n"),
        ("B.md", "---\nalias: Bee, Bea\n---\n"),
        ("C.md", "---\ntitle: x\naliases:\n  - Sea\n  - \"See Note\"\n---\n"),
        ("D.md", "---\naliases: >\n  folded\n---\n"),
        ("E.md", "aliases: [not, front matter]\n"),
        ("F.md", "---\nAliases: [Eff]\ntags: [t]\n---\n"),
    ]);
    let aliases = |p: &str| lib.note(&r("main", p)).unwrap().info.aliases;
    assert_eq!(aliases("A.md"), ["Alpha", "The A", "Aye"]);
    assert_eq!(aliases("B.md"), ["Bee", "Bea"]);
    assert_eq!(aliases("C.md"), ["Sea", "See Note"]);
    assert!(aliases("D.md").is_empty());
    assert!(aliases("E.md").is_empty());
    assert_eq!(aliases("F.md"), ["Eff"]);
    // The notes list carries them too, and the tags stay apart.
    let listed = lib.notes(&Filter::default(), Sort::NameAscending);
    assert_eq!(listed[0].aliases, ["Alpha", "The A", "Aye"]);
    assert_eq!(lib.note(&r("main", "F.md")).unwrap().info.tags, ["t"]);
}

#[test]
fn a_note_is_mentioned_by_its_title_its_stem_and_its_aliases() {
    let notes = [
        ("proj-x.md", "---\naliases: [Codename Ten]\n---\n# Project Ten\n"),
        ("a.md", "We talk about Project Ten today.\n"),
        ("b.md", "The file proj-x is the one.\n"),
        ("c.md", "Ask about codename ten on Monday.\n"),
        ("d.md", "Nothing here.\n"),
    ];
    assert_eq!(
        mention_view(&notes, "proj-x.md"),
        [pair("a.md", "Project Ten"), pair("b.md", "proj-x"), pair("c.md", "codename ten")]
    );
    let lib = lib_of(&notes);
    let names: Vec<String> = lib.mentions(&r("main", "proj-x.md")).into_iter().map(|m| m.name).collect();
    assert_eq!(names, ["Project Ten", "proj-x", "Codename Ten"]);
    let m = &lib.mentions(&r("main", "proj-x.md"))[0];
    assert_eq!((m.from_title.as_str(), m.context.as_str(), m.to.path.as_str()), ("a", "We talk about Project Ten today.", "proj-x.md"));
    assert_eq!(m.range, TextRange::new(14, 25));
    // A note that is not there has none.
    assert!(lib.mentions(&r("main", "nope.md")).is_empty());
}

#[test]
fn mentions_ignore_case_and_unicode_form_and_follow_the_encoding() {
    let nfc = "Caf\u{e9} Noir";
    let nfd = "Cafe\u{301} Noir";
    // NFC name, NFD text, and the reverse; any case.
    for (name, text) in [(nfc, nfd), (nfd, nfc), (nfc, "CAF\u{c9} NOIR"), (nfd, "caf\u{e9} noir")] {
        let notes = [("Target.md", &format!("# {name}\n")), ("From.md", &format!("Meet at {text}, ok.\n"))];
        let notes: Vec<(&str, &str)> = notes.iter().map(|(p, t)| (*p, t.as_str())).collect();
        assert_eq!(mention_view(&notes, "Target.md"), [pair("From.md", text)], "{name:?} in {text:?}");
    }
    // A file name in one form, text in the other.
    let notes = [(format!("{nfd}.md"), "x".to_owned()), ("From.md".to_owned(), format!("a {nfc} b"))];
    let notes: Vec<(&str, &str)> = notes.iter().map(|(p, t)| (p.as_str(), t.as_str())).collect();
    let lib = lib_of(&notes);
    let found = lib.mentions(&r("main", &format!("{nfd}.md")));
    assert_eq!(found.len(), 1);
    // The range is in UTF-16 units of the mentioning note's text.
    assert_eq!(found[0].range, TextRange::new(2, 11));
    // Wide characters before the match move it in UTF-16 but not in UTF-32.
    let text = "\u{1F389}\u{1F389} Alpha beta";
    let mut lib32 = Library::new(OffsetEncoding::Utf32);
    lib32.add_root("main", "/n");
    lib32.upsert(&r("main", "Alpha beta.md"), "x", 0).unwrap();
    lib32.upsert(&r("main", "From.md"), text, 0).unwrap();
    assert_eq!(lib32.mentions(&r("main", "Alpha beta.md"))[0].range, TextRange::new(3, 13));
    let lib16 = lib_of(&[("Alpha beta.md", "x"), ("From.md", text)]);
    assert_eq!(lib16.mentions(&r("main", "Alpha beta.md"))[0].range, TextRange::new(5, 15));
}

#[test]
fn a_mention_is_a_whole_word() {
    let notes = [
        ("caf\u{e9}.md", "x"),
        ("a.md", "Les caf\u{e9}s sont l\u{e0}.\n"),
        ("b.md", "decaf\u{e9} and caf\u{e9}2 and caf\u{e9}_x\n"),
        ("c.md", "Cafe\u{301} counts: (caf\u{e9}) and caf\u{e9}.\n"),
        ("d.md", "caf\u{e9}\u{301} has one more accent\n"),
    ];
    assert_eq!(mention_view(&notes, "caf\u{e9}.md"), [pair("b.md", "caf\u{e9}"), pair("c.md", "Cafe\u{301}"), pair("c.md", "caf\u{e9}"), pair("c.md", "caf\u{e9}")]);
}

#[test]
fn a_name_is_not_mentioned_where_something_already_is() {
    let doc = "# Heading\n\
        Plain: Zeta.\n\
        Code `Zeta` span.\n\
        A [link to Zeta](http://x.y/Zeta) and [Zeta][ref] and ![Zeta](img.png) here.\n\
        A [[Zeta]] and [[Other|Zeta]] and [[Zeta|shown]] wikilink, <http://x.y/Zeta> and http://x.y/Zeta bare.\n\
        <span title=\"Zeta\">Zeta</span> inline html (its text is prose, its attributes are not), and #Zeta a tag.\n\
        \n\
        ```\n\
        Zeta fenced\n\
        ```\n\
        \n\
        \x20   Zeta indented\n\
        \n\
        <div>\nZeta block\n</div>\n\
        \n\
        [ref]: http://x.y/ref\n\
        Zeta again.\n";
    let front = format!("---\ntitle: Zeta\nnote: Zeta\n---\n{doc}");
    let notes = [("Zeta.md", "x"), ("From.md", &front)];
    let found = mention_view(&notes, "Zeta.md");
    // Only the plain ones: the second line, the text between inline tags, and the last.
    assert_eq!(found, [pair("From.md", "Zeta"), pair("From.md", "Zeta"), pair("From.md", "Zeta")]);
    let lib = lib_of(&notes);
    let contexts: Vec<String> = lib.mentions(&r("main", "Zeta.md")).into_iter().map(|m| m.context).collect();
    assert_eq!(contexts[0], "Plain: Zeta.");
    assert!(contexts[1].starts_with("<span"));
    assert_eq!(contexts[2], "Zeta again.");
    // A name that spans the edge of a link is not a mention either.
    let notes = [("Foo Bar.md", "x"), ("From.md", "see Foo [Bar](u) and [Foo](u) Bar\n")];
    assert!(mention_view(&notes, "Foo Bar.md").is_empty());
}

#[test]
fn a_note_does_not_mention_itself_and_a_linked_note_lists_only_the_unlinked_places() {
    let notes = [
        ("Target.md", "Target is about Target, and Target again.\n"),
        ("From.md", "[[Target]] first, then Target in prose, and `Target` in code.\n"),
        ("Other.md", "[[Target|the target]] and nothing else\n"),
    ];
    assert_eq!(mention_view(&notes, "Target.md"), [pair("From.md", "Target")]);
    let lib = lib_of(&notes);
    assert_eq!(lib.backlinks(&r("main", "Target.md")).len(), 2);
    // Its own title and stem do not make the note a mention of itself even in a note of the same name elsewhere.
    assert!(lib.mentions(&r("main", "Other.md")).is_empty());
}

#[test]
fn names_shorter_than_two_characters_never_match() {
    let notes = [("A.md", "x"), ("\u{65E5}.md", "x"), ("From.md", "A a A \u{65E5} and \u{65E5}\u{672C}\n"), ("\u{65E5}\u{672C}.md", "x")];
    assert!(mention_view(&notes, "A.md").is_empty());
    assert!(mention_view(&notes, "\u{65E5}.md").is_empty());
    // Two ideographs are a name, found inside a run of them (they have no spaces to bound a word).
    assert_eq!(mention_view(&notes, "\u{65E5}\u{672C}.md"), [pair("From.md", "\u{65E5}\u{672C}")]);
    // A one-character title or alias is dropped, the stem still counts.
    let notes = [("Longer.md", "---\naliases: [x, Ab]\n---\n# Q\n"), ("From.md", "x and q and Ab and Longer\n")];
    assert_eq!(mention_view(&notes, "Longer.md"), [pair("From.md", "Ab"), pair("From.md", "Longer")]);
}

#[test]
fn overlapping_names_keep_the_longest_and_one_text_is_one_mention() {
    let notes = [
        ("Plan.md", "---\naliases: [Plan Alpha]\n---\n# Plan Alpha Roadmap\n"),
        ("From.md", "The Plan Alpha Roadmap, the Plan Alpha, the plan.\n"),
    ];
    assert_eq!(mention_view(&notes, "Plan.md"), [pair("From.md", "Plan Alpha Roadmap"), pair("From.md", "Plan Alpha"), pair("From.md", "plan")]);
    // A title that equals the stem is one name.
    let lib = lib_of(&[("Same.md", "# Same\n"), ("From.md", "same\n")]);
    assert_eq!(lib.mentions(&r("main", "Same.md")).len(), 1);
}

#[test]
fn mentions_are_sorted_by_root_then_path_then_position_and_follow_the_texts() {
    let mut lib = Library::new(ENC);
    lib.add_root("main", "/n");
    lib.add_root("work", "/w");
    lib.upsert(&r("main", "Topic.md"), "x", 0).unwrap();
    lib.upsert(&r("work", "A.md"), "topic", 0).unwrap();
    lib.upsert(&r("main", "Z.md"), "topic, TOPIC", 0).unwrap();
    lib.upsert(&r("main", "B.md"), "a topic", 0).unwrap();
    let order: Vec<(String, String, u32)> = lib.mentions(&r("main", "Topic.md")).into_iter().map(|m| (m.from.root, m.from.path, m.range.start)).collect();
    assert_eq!(
        order,
        [("main".to_owned(), "B.md".to_owned(), 2), ("main".to_owned(), "Z.md".to_owned(), 0), ("main".to_owned(), "Z.md".to_owned(), 7), ("work".to_owned(), "A.md".to_owned(), 0)]
    );
    // Editing a note changes what it mentions at once; removing it takes its mentions away.
    lib.upsert(&r("main", "B.md"), "a [[Topic]]", 1).unwrap();
    lib.remove(&r("work", "A.md"));
    assert_eq!(lib.mentions(&r("main", "Topic.md")).len(), 2);
}

/// The text of `from` after the edit `lib` gives for the first mention of `to` in it.
fn linked(notes: &[(&str, &str)], to: &str, from: &str) -> Option<String> {
    let lib = lib_of(notes);
    let m = lib.mentions(&r("main", to)).into_iter().find(|m| m.from.path == from)?;
    let e = lib.link_mention_edit(&m)?;
    assert_eq!((e.note.path.as_str(), e.range), (from, m.range));
    let text = notes.iter().find(|(p, _)| *p == from).unwrap().1;
    let (s, t) = (utf16_to_byte(text, e.range.start), utf16_to_byte(text, e.range.end));
    let mut out = text.to_owned();
    out.replace_range(s..t, &e.replacement);
    Some(out)
}

#[test]
fn linking_a_mention_wraps_the_stem_or_labels_the_title() {
    let notes = [
        ("Ideas.md", "---\naliases: [Brainstorm]\n---\n# Big Ideas\n"),
        ("a.md", "My ideas are here.\n"),
        ("b.md", "The big ideas list.\n"),
        ("c.md", "Our BRAINSTORM notes.\n"),
        ("d.md", "Our IDEAS, written in capitals.\n"),
    ];
    // The stem in any case keeps the written case.
    assert_eq!(linked(&notes, "Ideas.md", "a.md").unwrap(), "My [[ideas]] are here.\n");
    assert_eq!(linked(&notes, "Ideas.md", "d.md").unwrap(), "Our [[IDEAS]], written in capitals.\n");
    // The title and an alias are labels over the stem.
    assert_eq!(linked(&notes, "Ideas.md", "b.md").unwrap(), "The [[Ideas|big ideas]] list.\n");
    assert_eq!(linked(&notes, "Ideas.md", "c.md").unwrap(), "Our [[Ideas|BRAINSTORM]] notes.\n");
    // Applied, the mention is a backlink and no longer a mention.
    let mut lib = lib_of(&notes);
    let m = lib.mentions(&r("main", "Ideas.md")).into_iter().find(|m| m.from.path == "b.md").unwrap();
    let e = lib.link_mention_edit(&m).unwrap();
    lib.upsert(&r("main", "b.md"), &linked(&notes, "Ideas.md", "b.md").unwrap(), 9).unwrap();
    assert_eq!(e.replacement, "[[Ideas|big ideas]]");
    assert!(lib.backlinks(&r("main", "Ideas.md")).iter().any(|b| b.from.path == "b.md"));
    assert!(lib.mentions(&r("main", "Ideas.md")).iter().all(|m| m.from.path != "b.md"));
}

#[test]
fn linking_a_mention_uses_a_folder_when_another_note_has_the_stem() {
    let notes = [
        ("Work/Plan.md", "x"),
        ("Home/Plan.md", "x"),
        ("Home/Note.md", "The plan is simple.\n"),
        ("Other/Note.md", "The plan is simple.\n"),
        ("Loose.md", "The plan is simple.\n"),
    ];
    let lib = lib_of(&notes);
    // From the same folder the bare stem is nearest; from elsewhere, where the nearest is the other one, the folder is named.
    let edit = |to: &str, from: &str| {
        let m = lib.mentions(&r("main", to)).into_iter().find(|m| m.from.path == from).unwrap();
        lib.link_mention_edit(&m).unwrap().replacement
    };
    assert_eq!(edit("Home/Plan.md", "Home/Note.md"), "[[plan]]");
    assert_eq!(edit("Work/Plan.md", "Home/Note.md"), "[[Work/Plan|plan]]");
    // Whatever it names, the link lands on the mentioned note.
    for (to, from) in [("Home/Plan.md", "Other/Note.md"), ("Work/Plan.md", "Other/Note.md"), ("Work/Plan.md", "Loose.md"), ("Home/Plan.md", "Loose.md")] {
        let e = edit(to, from);
        let target = e.trim_start_matches("[[").split(['|', ']']).next().unwrap();
        assert_eq!(lib.resolve_wikilink(&r("main", from), target), Some(r("main", to)), "{e} from {from}");
    }
}

#[test]
fn linking_a_stale_mention_gives_nothing() {
    let mut lib = lib_of(&[("Topic.md", "x"), ("From.md", "see Topic here\n"), ("Other.md", "unrelated\n")]);
    let m = lib.mentions(&r("main", "Topic.md")).remove(0);
    assert!(lib.link_mention_edit(&m).is_some());
    // The text moved, so the range holds something else.
    lib.upsert(&r("main", "From.md"), "now see Topic here\n", 1).unwrap();
    assert!(lib.link_mention_edit(&m).is_none());
    // The text is the same word again, but in a link or code now.
    lib.upsert(&r("main", "From.md"), "see `Topic` here\n", 2).unwrap();
    assert!(lib.link_mention_edit(&m).is_none());
    lib.upsert(&r("main", "From.md"), "see Topical here\n", 3).unwrap();
    assert!(lib.link_mention_edit(&m).is_none());
    // The mentioning or the mentioned note is gone, or the mention is made up.
    lib.upsert(&r("main", "From.md"), "see Topic here\n", 4).unwrap();
    assert!(lib.link_mention_edit(&m).is_some());
    let wrong_name = Mention { name: "Other".to_owned(), ..m.clone() };
    assert!(lib.link_mention_edit(&wrong_name).is_none());
    lib.remove(&r("main", "Topic.md"));
    assert!(lib.link_mention_edit(&m).is_none());
}

// ----- the Opus pass, 7 October -------------------------------------------------------------------------------------

#[test]
fn a_name_the_brackets_cannot_make_a_link_of_gets_no_edit() {
    // `[[__init__]]` is bold text in brackets to the parser: no link, so the mention stayed and Link pressed again
    // wrapped it again (`[[[[__init__]]]]`).
    for name in ["__init__", "_under_", "*star*", "**bold**", "~~gone~~"] {
        let target = format!("{name}.md");
        let notes = [(target.as_str(), "x"), ("From.md", "See it: NAME here.\n")];
        let text = notes[1].1.replace("NAME", name);
        let notes = [notes[0], ("From.md", text.as_str())];
        let lib = lib_of(&notes);
        let m = lib.mentions(&r("main", &target));
        assert_eq!(m.len(), 1, "{name}: the mention is still listed");
        assert_eq!(lib.link_mention_edit(&m[0]), None, "{name}");
    }
    // Names with other punctuation link, and the link is a backlink once written.
    for name in ["C++ Notes", "a*b", "(paren)", "a.b", "Dollar $5", "_index", "a_b_c", "50% off", "back`tick", "emoji \u{1F389}"] {
        let target = format!("{name}.md");
        let text = format!("See {name} here.\n");
        let linked_text = linked(&[(target.as_str(), "x"), ("From.md", text.as_str())], &target, "From.md").unwrap_or_else(|| panic!("{name}"));
        let lib = lib_of(&[(target.as_str(), "x"), ("From.md", linked_text.as_str())]);
        assert_eq!(lib.backlinks(&r("main", &target)).len(), 1, "{name}: {linked_text}");
        assert!(lib.mentions(&r("main", &target)).is_empty(), "{name}");
    }
}

#[test]
fn mentions_at_the_edges_of_odd_texts() {
    let notes = [
        ("Edge.md", "---\naliases: [Rim, rim, '', ' ', \"\", Edge]\n---\nx"),
        // At the very start and end, with no line ending; lines ended by a lone CR; a front matter title.
        ("A.md", "Edge first and last Edge"),
        ("B.md", "line\rRim\rend"),
        ("C.md", "---\ntitle: Edge\n---\nbody"),
    ];
    assert_eq!(mention_view(&notes, "Edge.md"), [pair("A.md", "Edge"), pair("A.md", "Edge"), pair("B.md", "Rim")]);
    let lib = lib_of(&notes);
    let names: Vec<String> = lib.mentions(&r("main", "Edge.md")).into_iter().map(|m| m.name).collect();
    assert_eq!(names, ["Edge", "Edge", "Rim"]);
    let cr = lib.mentions(&r("main", "Edge.md")).into_iter().find(|m| m.from.path == "B.md").unwrap();
    assert_eq!(cr.context, "Rim");
    assert_eq!(linked(&notes, "Edge.md", "A.md").unwrap(), "[[Edge]] first and last Edge");
}

#[test]
fn two_thousand_notes_mentioning_one_are_found_quickly() {
    let mut owned: Vec<(String, String)> = vec![("Hub.md".into(), "# Hub\n".into())];
    for i in 0..2000 {
        owned.push((format!("n{i}.md"), format!("Note {i} talks about the hub and Hub again, then more words.\n")));
    }
    let notes: Vec<(&str, &str)> = owned.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
    let lib = lib_of(&notes);
    let t = std::time::Instant::now();
    assert_eq!(lib.mentions(&r("main", "Hub.md")).len(), 4000);
    let ms = t.elapsed().as_secs_f64() * 1000.0;
    // 53 ms in a debug build on the machine of the 7 October pass.
    assert!(ms < 1000.0, "{ms:.0} ms");
}
