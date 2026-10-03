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

const PATHS: [&str; 8] = ["a.md", "b.md", "x/a.md", "x/c.md", "x/y/b.md", "x/y/z/Sub.md", "c.txt", "d.md"];
const ROOTS: [&str; 2] = ["r1", "r2"];

fn note_of(i: usize) -> NoteRef {
    r(ROOTS[(i / PATHS.len()) % 2], PATHS[i % PATHS.len()])
}

fn note_text() -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "[[a]] ", "[[b|x]] ", "[[sub/c]] ", "[[x/a]] ", "[[#h]] ", "[[A#h]] ", "[[Title]] ", "[[zeta]] ", "#t1 ", "#t/u ", "# Title\n",
        "# a\n", "## h\n", "word ", "zeta ", "alpha ", "beta ", "\n", "\n\n", "---\ntags: [x, t1]\n---\n", "`[[a]]` ", "[l](u) ", "\u{e9}t\u{e9} ",
        "\u{65E5}\u{672C} ", "#", "[[", "]]", "| ",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..12).prop_map(|v| v.concat())
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0usize..16, note_text()).prop_map(|(i, t)| Op::Upsert(i, t)),
        2 => (0usize..16).prop_map(Op::Remove),
        2 => (0usize..16, 0usize..16).prop_map(|(a, b)| Op::Rename(a, b)),
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
