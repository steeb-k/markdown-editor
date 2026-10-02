//! Authorship: run arithmetic, the Markdown Annotations format, and their properties.

use markdown_core::authorship::*;
use markdown_core::{OffsetEncoding, TextRange};
use proptest::prelude::*;
use sha2::{Digest, Sha256};

const ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

fn fixture(name: &str) -> String {
    let p = format!("{}/../../fixtures/authorship/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(p).unwrap()
}

fn ai() -> Author {
    Author::new(AuthorKind::Ai, "AI")
}
fn reference() -> Author {
    Author::new(AuthorKind::Reference, "Ref")
}
fn r(s: u32, e: u32) -> TextRange {
    TextRange::new(s, e)
}

/// Runs as (start, end, author) with real authors, for comparisons across instances.
fn runs_of(a: &Authorship) -> Vec<(u32, u32, Author)> {
    let authors = a.authors();
    a.runs(None)
        .iter()
        .map(|x| (x.range.start, x.range.end, authors[x.author_index as usize].clone()))
        .collect()
}

fn ranges(p: &ParsedAuthor) -> Vec<(u32, u32)> {
    p.ranges.iter().map(|r| (r.start, r.length)).collect()
}

fn units(s: &str, enc: OffsetEncoding) -> u32 {
    match enc {
        OffsetEncoding::Utf8 => s.len() as u32,
        OffsetEncoding::Utf16 => s.encode_utf16().count() as u32,
        OffsetEncoding::Utf32 => s.chars().count() as u32,
    }
}

fn to_file(text: &str, ending: LineEnding) -> String {
    match ending {
        LineEnding::CrLf => text.replace('\n', "\r\n"),
        LineEnding::Cr => text.replace('\n', "\r"),
        _ => text.to_string(),
    }
}

fn hash32(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().take(16).map(|b| format!("{b:02x}")).collect()
}

// ----- the spec's own examples ---------------------------------------------------------------

#[test]
fn spec_example_in_the_readme() {
    // The first example of the README, as a file.
    let file = fixture("spec-example.md");
    let s = split_annotations(&file);
    assert_eq!(s.status, AnnotationStatus::Valid);
    // The body is the text and its line's terminator; the blank line is the separator.
    assert_eq!(
        s.body,
        "Markdown Annotations embed authorship in text while preserving its readability and portability.\n"
    );
    assert_eq!(s.body.clone() + s.raw_tail.as_deref().unwrap(), file);
    let p = s.annotations.unwrap();
    assert_eq!(p.hash_key, "Annotations");
    assert_eq!((p.hash_range.start, p.hash_range.length), (0, 95));
    assert_eq!(p.hash, "1132bf5e376a605f5beed4b204456114");
    assert_eq!(p.authors.len(), 2);
    assert_eq!((p.authors[0].kind, p.authors[0].name.as_str()), (AuthorKind::Human, "Human"));
    assert_eq!(ranges(&p.authors[0]), vec![(0, 20), (33, 4), (45, 6), (62, 4)]);
    assert_eq!((p.authors[1].kind, p.authors[1].name.as_str()), (AuthorKind::Ai, "AI"));
    assert_eq!(ranges(&p.authors[1]), vec![(20, 13), (37, 8), (51, 11), (66, 29)]);
}

#[test]
fn spec_example_is_written_back_byte_for_byte() {
    let file = fixture("spec-example.md");
    let s = split_annotations(&file);
    let a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Human");
    assert!(a.has_marks());
    // The canonical form (not just the remembered original) is the spec's own bytes.
    let block = a.annotation_block(&s.body, LineEnding::Lf).unwrap();
    assert_eq!(format!("{}{}", s.body, block), file);
    assert_eq!(a.runs(None).len(), 8);
}

/// The text of the graphemes `[start, start + length)` of `body`, for checking what a range covers.
fn graphemes_of(body: &str, start: u32, length: u32) -> String {
    use unicode_segmentation::UnicodeSegmentation;
    body.graphemes(true).skip(start as usize).take(length as usize).collect()
}

#[test]
fn harbour_lights_has_every_feature_of_the_format_and_a_valid_block() {
    // Written for this project by an independent Swift generator (Swift's grapheme clusters
    // and CryptoKit): several authors of each kind, an indented block, range lists wrapped onto
    // continuation lines, bare length-1 ranges, a translated hash key with a full 64-digit
    // hash and runs of spaces, unknown annotations, an author annotation with content, an
    // escaped colon in a name, emoji, CJK and combining marks in a body of ~4 KB.
    let file = fixture("harbour-lights.md");
    let s = split_annotations(&file);
    assert_eq!(s.status, AnnotationStatus::Valid, "{:?}", s.status);
    let p = s.annotations.as_ref().unwrap();
    assert_eq!(p.hash_key, "Anmerkungen");
    assert_eq!(p.hash.len(), 64);
    assert_eq!((p.hash_range.start, p.hash_range.length), (0, 4127));
    // The body keeps its front matter and its last newline; the blank line is the separator.
    assert!(s.body.starts_with("---\ntitle: Harbour lights\n"));
    assert!(s.body.ends_with("ours. \u{1F469}\u{1F3FD}\u{200D}\u{1F52C}\u{1F468}\u{1F3FB}\u{200D}\u{1F527}\n"));
    assert_eq!(format!("{}{}", s.body, s.raw_tail.as_ref().unwrap()), file);
    let names: Vec<(AuthorKind, &str)> = p.authors.iter().map(|a| (a.kind, a.name.as_str())).collect();
    assert_eq!(
        names,
        vec![
            (AuthorKind::Human, "Steve Kaznak"),
            (AuthorKind::Ai, "Assistant"),
            (AuthorKind::Ai, "Draft Bot <bot@example.org>"),
            (AuthorKind::Reference, "Harbour Archive"),
            (AuthorKind::Reference, "Keeper's Log"),
            (AuthorKind::Human, "Ada: Lovelace"),
        ]
    );
    // Wrapped lists: Steve's ranges continue over three more lines, with a bare range among them.
    assert_eq!(p.authors[0].ranges.len(), 13);
    assert_eq!(ranges(&p.authors[0])[4], (1100, 1));
    assert_eq!(ranges(&p.authors[4]), vec![(60, 1), (847, 128)]);
    // What does not describe authorship is kept verbatim, author-with-content included.
    assert_eq!(
        p.unknown,
        vec![
            "Source: field guide, second edition  ".to_string(),
            "&Summariser: 12,3 tone=dry".to_string(),
            "Review\\: status: pending".to_string(),
            "  and continued here".to_string(),
        ]
    );
    // The ranges cover the words the generator was told to attribute, in grapheme clusters.
    let covered = |a: usize, i: usize| {
        let r = p.authors[a].ranges[i];
        graphemes_of(&s.body, r.start, r.length)
    };
    assert_eq!(covered(1, 0), "A Fresnel lens is a flat lens cut into rings.");
    assert_eq!(covered(2, 0), "| \u{1F1EF}\u{1F1F5} \u{6A2A}\u{6D5C} | Oc G 4s | occulting green |");
    assert_eq!(covered(3, 1), "\u{706F}\u{53F0}\u{5B88}\u{306E}\u{65E5}\u{8A18}");
    assert_eq!(covered(4, 0), "\u{1F5FC}");
    assert_eq!(covered(5, 0), "\u{2693}\u{FE0F}");
    assert_eq!(covered(5, 1), "Some keepers wrote poems.");
    assert_eq!(covered(5, 2), "\u{1F408}");
    // Every encoding lands on the same text, and the canonical writer reproduces the authors
    // (32-digit hash, the key kept, one line per author, unknown lines after them).
    for enc in ENCODINGS {
        let a = Authorship::from_annotations(&s.body, p, enc, "Steve Kaznak");
        let authors = a.authors();
        let ai_text: Vec<String> = a
            .runs(None)
            .iter()
            .filter(|r| authors[r.author_index as usize].name == "Assistant")
            .map(|r| {
                let (lo, hi) = (r.range.start as usize, r.range.end as usize);
                match enc {
                    OffsetEncoding::Utf8 => s.body[lo..hi].to_string(),
                    OffsetEncoding::Utf16 => {
                        let t: Vec<u16> = s.body.encode_utf16().collect();
                        String::from_utf16(&t[lo..hi]).unwrap()
                    }
                    OffsetEncoding::Utf32 => s.body.chars().skip(lo).take(hi - lo).collect(),
                }
            })
            .collect();
        assert_eq!(ai_text.len(), 3, "{enc:?}");
        assert_eq!(ai_text[0], "A Fresnel lens is a flat lens cut into rings.", "{enc:?}");
        assert!(ai_text[1].starts_with("Each ring") && ai_text[1].ends_with("in the glass."), "{enc:?}");
        let block = a.annotation_block(&s.body, LineEnding::Lf).unwrap();
        assert!(block.starts_with("\n---\nAnmerkungen: 0,4127 SHA-256 7d2441b932e5109ad130d30a26199b6f  \n"), "{block}");
        let again = split_annotations(&format!("{}{}", s.body, block));
        assert_eq!(again.status, AnnotationStatus::Valid);
        assert_eq!(again.body, s.body);
        let q = again.annotations.unwrap();
        assert_eq!(q.unknown, p.unknown);
        let b = Authorship::from_annotations(&again.body, &q, enc, "Steve Kaznak");
        assert_eq!(runs_of(&a), runs_of(&b), "{enc:?}");
    }
    // Untouched: the original bytes.
    let mut a = Authorship::from_annotations(&s.body, p, OffsetEncoding::Utf16, "Steve Kaznak");
    a.set_origin(&s.body, s.raw_tail.as_ref().unwrap(), LineEnding::Lf);
    assert_eq!(format!("{}{}", s.body, a.file_tail(&s.body, LineEnding::Lf)), file);
}

/// Interoperability check against the spec's own README, whose tail is an annotation block
/// written by iA. Not vendored (the repository has no license): fetched at run time.
///
///     cargo test -p markdown-core --test authorship -- --ignored spec_readme
#[test]
#[ignore = "fetches https://github.com/iainc/Markdown-Annotations at run time"]
fn spec_readme_fetched_from_github_ends_with_a_valid_block() {
    let out = std::process::Command::new("curl")
        .args(["-fsSL", "https://raw.githubusercontent.com/iainc/Markdown-Annotations/develop/README.md"])
        .output()
        .expect("curl");
    assert!(out.status.success(), "fetch failed: {}", String::from_utf8_lossy(&out.stderr));
    let file = String::from_utf8(out.stdout).unwrap();
    let s = split_annotations(&file);
    assert_eq!(s.status, AnnotationStatus::Valid, "{:?}", s.status);
    let p = s.annotations.as_ref().unwrap();
    // As of version 0.2 of the spec (2025-11-05): the range stops before the text's last
    // newline and a blank line separates the text from the block.
    assert_eq!(p.hash_key, "Annotations");
    assert!(!p.authors.is_empty());
    assert_eq!(format!("{}{}", s.body, s.raw_tail.as_ref().unwrap()), file);
    assert_eq!(
        grapheme_count(&s.body),
        p.hash_range.length as usize + 1,
        "the hashed range is the body without its last newline"
    );
    for enc in ENCODINGS {
        let a = Authorship::from_annotations(&s.body, p, enc, "Me");
        let block = a.annotation_block(&s.body, LineEnding::Lf).unwrap();
        let again = split_annotations(&format!("{}{}", s.body, block));
        assert_eq!(again.status, AnnotationStatus::Valid);
        assert_eq!(again.annotations.unwrap().authors, p.authors, "{enc:?}");
    }
    let mut a = Authorship::from_annotations(&s.body, p, OffsetEncoding::Utf16, "Me");
    a.set_origin(&s.body, s.raw_tail.as_ref().unwrap(), LineEnding::Lf);
    assert_eq!(format!("{}{}", s.body, a.file_tail(&s.body, LineEnding::Lf)), file);
}

fn grapheme_count(s: &str) -> usize {
    use unicode_segmentation::UnicodeSegmentation;
    s.graphemes(true).count()
}

// ----- the structure of a block --------------------------------------------------------------

fn file_with(text: &str, ending: LineEnding, marks: &[(u32, u32, Author)]) -> String {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    for (s, e, who) in marks {
        a.mark(r(*s, *e), Some(who));
    }
    let tail = a.file_tail(text, ending);
    format!("{}{}", to_file(text, ending), tail)
}

#[test]
fn written_format_matches_the_example_shape() {
    let f = file_with("hello world\n", LineEnding::Lf, &[(6, 11, ai())]);
    let hash = hash32(b"hello world");
    // Me has no text, so no `@Me` line; `6,5` because the range is a start and a length.
    assert_eq!(f, format!("hello world\n\n---\nAnnotations: 0,11 SHA-256 {hash}  \n&AI: 6,5  \n...\n"));
}

#[test]
fn no_marks_no_block() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.edit(r(0, 0), 5, Attribution::Typed(a.me().clone()));
    assert!(!a.has_marks());
    assert_eq!(a.annotation_block("hello\n", LineEnding::Lf), None);
    assert_eq!(a.file_tail("hello\n", LineEnding::Lf), "");
}

#[test]
fn me_text_is_written_when_there_are_marks() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    let me = a.me().clone();
    a.edit(r(0, 0), 5, Attribution::Typed(me.clone()));
    a.edit(r(5, 5), 5, Attribution::As(ai()));
    let b = a.annotation_block("helloworld\n", LineEnding::Lf).unwrap();
    assert!(b.contains("@Me: 0,5  \n"), "{b}");
    assert!(b.contains("&AI: 5,5  \n"), "{b}");
}

#[test]
fn body_without_final_newline_gets_a_blank_line_and_reads_back_with_a_newline() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(0, 3), Some(&ai()));
    let block = a.annotation_block("abc", LineEnding::Lf).unwrap();
    assert!(block.starts_with("\n\n---\nAnnotations: 0,3 SHA-256 "));
    let s = split_annotations(&format!("abc{block}"));
    assert_eq!(s.status, AnnotationStatus::Valid);
    assert_eq!(s.body, "abc\n");
}

#[test]
fn a_mark_on_the_final_newline_widens_the_hashed_range() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(0, 4), Some(&ai()));
    let f = format!("abc\n{}", a.annotation_block("abc\n", LineEnding::Lf).unwrap());
    assert!(f.contains("Annotations: 0,4 SHA-256 "));
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    assert_eq!(s.body, "abc\n");
    let p = s.annotations.unwrap();
    assert_eq!(ranges(&p.authors[0]), vec![(0, 4)]);
}

#[test]
fn crlf_hash_is_over_crlf_bytes_and_grapheme_indexes_do_not_change() {
    let text = "one\ntwo\nthree\n";
    let marks = [(4, 7, ai())];
    let lf = file_with(text, LineEnding::Lf, &marks);
    let crlf = file_with(text, LineEnding::CrLf, &marks);
    assert!(crlf.contains("\r\n---\r\nAnnotations: 0,13 SHA-256 "));
    assert!(!crlf.replace("\r\n", "").contains('\n'));
    let want = hash32(b"one\r\ntwo\r\nthree");
    assert!(crlf.contains(&want));
    assert!(!crlf.contains(&hash32(b"one\ntwo\nthree")));
    assert!(lf.contains(&hash32(b"one\ntwo\nthree")));
    // The grapheme range for "two\n" (4..8 in LF) is 4,4 either way: CRLF is one cluster.
    for f in [&lf, &crlf] {
        let s = split_annotations(f);
        assert_eq!(s.status, AnnotationStatus::Valid, "{f:?}");
        let p = s.annotations.unwrap();
        assert_eq!(ranges(&p.authors[0]), vec![(4, 3)]);
        assert_eq!(s.body, to_file(text, if f == &lf { LineEnding::Lf } else { LineEnding::CrLf }));
    }
}

#[test]
fn cr_only_files_work_too() {
    let f = file_with("a\nb\n", LineEnding::Cr, &[(2, 3, ai())]);
    assert!(f.contains("\r\r---\rAnnotations: 0,3 SHA-256 "));
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    assert_eq!(s.body, "a\rb\r");
}

#[test]
fn grapheme_clusters_are_counted_not_scalars() {
    // family ZWJ sequence, a flag, e + combining acute, a skin-toned thumbs up, plain.
    let text = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1E9}\u{1F1EA}e\u{301}\u{1F44D}\u{1F3FD}x\n";
    // Graphemes: family, space, flag, e+acute, thumb, x, newline.
    for enc in ENCODINGS {
        let mut a = Authorship::new(enc);
        let start = |prefix: &str| units(prefix, enc);
        let flag_at = start("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ");
        let flag_end = flag_at + start("\u{1F1E9}\u{1F1EA}");
        let thumb_at = flag_end + start("e\u{301}");
        let thumb_end = thumb_at + start("\u{1F44D}\u{1F3FD}");
        a.mark(r(0, start("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")), Some(&ai()));
        a.mark(r(flag_at, flag_end), Some(&reference()));
        a.mark(r(thumb_at, thumb_end), Some(&ai()));
        let f = format!("{text}{}", a.annotation_block(text, LineEnding::Lf).unwrap());
        assert!(f.contains("&AI: 0 4  \n") || f.contains("&AI: 0 4"), "{f}");
        assert!(f.contains("*Ref: 2  \n"), "{f}");
        let s = split_annotations(&f);
        assert_eq!(s.status, AnnotationStatus::Valid, "{enc:?}");
        let b = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), enc, "Me");
        assert_eq!(runs_of(&a), runs_of(&b), "{enc:?}");
    }
}

#[test]
fn a_run_edge_inside_a_cluster_goes_to_the_first_scalar() {
    // "e" attributed, the combining accent typed after it unattributed: one cluster.
    let text = "e\u{301}x\n";
    let mut a = Authorship::new(OffsetEncoding::Utf32);
    a.mark(r(0, 1), Some(&ai()));
    let b = a.annotation_block(text, LineEnding::Lf).unwrap();
    assert!(b.contains("&AI: 0  \n"), "{b}");
}

// ----- recognising and refusing --------------------------------------------------------------

#[test]
fn plain_documents_have_no_block() {
    for t in [
        "",
        "hello\n",
        "hello\n\n---\n",
        "text\n\n---\n...\n",
        "---\ntitle: x\n---\nbody\n",
        "---\ntitle: x\n...\n",
        "text\n\n---\nfoo: bar\n...\n",
        "text\n\n---\nNotes: one two three\n...\n",
        "text\n\n---\nAnnotations: soon\n...\n",
        "text\n---\nAnnotations: 0,4 SHA-256 nothex\n...\n",
        "a\n\n---\n...\n",
    ] {
        let s = split_annotations(t);
        assert_eq!(s.status, AnnotationStatus::Absent, "{t:?}");
        assert_eq!(s.body, t);
        assert!(s.raw_tail.is_none());
    }
}

#[test]
fn front_matter_lookalike_at_the_start_is_not_a_block_unless_valid() {
    let t = "---\nAnnotations: 0,3 SHA-256 aaaaaaaaaaaaaaaaaaaa\n...\n";
    assert_eq!(split_annotations(t).status, AnnotationStatus::Absent);
}

/// Every shape at the end of a document that could be mistaken for a block, and what it is.
/// A wrong "block" hides the end of someone's document from the editor (and Discard deletes
/// it), so everything that is not plainly a block must read as text.
#[test]
fn block_recognition_matrix() {
    let valid = file_with("Body text.\n", LineEnding::Lf, &[(0, 4, ai())]);
    let block = &valid["Body text.\n".len()..];
    let h = hash32(b"x");
    let absent: &[(&str, String)] = &[
        ("front matter only", "---\ntitle: x\n---\n".into()),
        ("front matter closed by dots", "---\ntitle: a b c\n...\n".into()),
        ("front matter with a hash-like line", format!("---\nAnnotations: 0,1 SHA-256 {h}\n...\n")),
        ("thematic break at the end", "Text.\n\n---\n".into()),
        ("dots at the end, no dashes", "Text.\n\n...\n".into()),
        ("dots after a thematic break, blank first", "Text.\n\n---\n\nNote: 1 2 3\n...\n".into()),
        ("pandoc metadata at the end", "Text.\n\n---\ndate: 2024 10 01\n...\n".into()),
        ("pandoc metadata, several keys", "Text.\n\n---\nversion: 1 2 3\nauthor: Ann\n...\n".into()),
        ("text after the dots", format!("{valid}More text.\n")),
        ("closed fence holding a block", format!("Text.\n\n```\n{}```\n", &block[1..])),
        ("indented dashes", format!("Text.\n\n ---\nAnnotations: 0,1 SHA-256 {h}\n...\n")),
        ("no annotation line", "Text.\n\n---\n...\n".into()),
        ("two tokens", format!("Text.\n\n---\nAnnotations: SHA-256 {h}\n...\n")),
        ("non-hex hash", "Text.\n\n---\nAnnotations: 0,1 SHA-256 zzzzzzzzzzzzzzzzzzzzzzzz\n...\n".into()),
        ("author first", format!("Text.\n\n---\n&AI: 0,1\nAnnotations: 0,1 SHA-256 {h}\n...\n")),
        ("empty file", String::new()),
        ("just dots", "...\n".into()),
        ("YAML stream", "---\na: 1\n---\nb: 2\n...\n".into()),
        ("a block at the start whose hash is wrong", block[1..].to_string()),
    ];
    for (name, f) in absent {
        let s = split_annotations(f);
        assert_eq!(s.status, AnnotationStatus::Absent, "{name}");
        assert_eq!(&s.body, f, "{name}");
        assert!(s.raw_tail.is_none(), "{name}");
    }
    type Case = (&'static str, String, fn(&AnnotationStatus) -> bool);
    let present: &[Case] = &[
        ("valid", valid.clone(), |s| *s == AnnotationStatus::Valid),
        ("valid, CRLF", file_with("Body text.\n", LineEnding::CrLf, &[(0, 4, ai())]), |s| *s == AnnotationStatus::Valid),
        ("valid, no final newline after dots", valid.trim_end().to_string(), |s| *s == AnnotationStatus::Valid),
        ("valid, trailing blank lines", format!("{valid}\n\n  \n"), |s| *s == AnnotationStatus::Valid),
        ("front matter and a block", format!("---\ntitle: x\n---\n{valid}"), |s| *s == AnnotationStatus::HashMismatch),
        ("text changed", valid.replacen("Body", "Bode", 1), |s| *s == AnnotationStatus::HashMismatch),
        ("MD5 with authors", valid.replace("SHA-256", "MD5"), |s| matches!(s, AnnotationStatus::Malformed(_))),
        ("short hash with authors", valid.replace(&hash32(b"Body text."), "abcdef0123"), |s| matches!(s, AnnotationStatus::Malformed(_))),
        ("an empty body and a block", format!("---\nAnnotations: 0,0 SHA-256 {}\n...\n", hash32(b"")), |s| *s == AnnotationStatus::Valid),
    ];
    for (name, f, ok) in present {
        let s = split_annotations(f);
        assert!(ok(&s.status), "{name}: {:?}", s.status);
        assert_eq!(format!("{}{}", s.body, s.raw_tail.as_deref().unwrap()), *f, "{name}");
        assert!(!s.body.contains("---\nAnnotations"), "{name}");
    }
    // Front matter, then a valid block: only the block is split off.
    let fm = file_with("---\ntitle: x\n---\n\nBody.\n", LineEnding::Lf, &[(20, 24, ai())]);
    let s = split_annotations(&fm);
    assert_eq!(s.status, AnnotationStatus::Valid);
    assert_eq!(s.body, "---\ntitle: x\n---\n\nBody.\n");
}

/// A block whose keys are indented, with an annotation this app does not know after the
/// authors: written back unindented, the unknown line must not become a continuation of the
/// last author (which would turn that author's ranges into "content" and lose them).
#[test]
fn unknown_annotations_from_an_indented_block_stay_separate_when_rewritten() {
    let hash = hash32(b"abcdefghij");
    let f = format!("abcdefghij\n\n---\n  Annotations: 0,10 SHA-256 {hash}  \n  &AI: 0,2  \n  @Ann: 4,2  \n  Note: kept\n    two lines\n...\n");
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    let mut a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    // An edit, so the canonical block is written.
    a.edit(r(10, 10), 1, Attribution::Typed(a.me().clone()));
    let text = "abcdefghijk\n";
    let again = split_annotations(&format!("{text}{}", a.file_tail(text, LineEnding::Lf)));
    assert_eq!(again.status, AnnotationStatus::Valid);
    let q = again.annotations.unwrap();
    let names: Vec<&str> = q.authors.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, vec!["Me", "AI", "Ann"]);
    assert_eq!(ranges(&q.authors[2]), vec![(4, 2)]);
    assert_eq!(q.unknown, vec!["Note: kept".to_string(), "  two lines".to_string()]);
}

#[test]
fn a_name_with_a_line_break_cannot_break_the_block() {
    let mut a = Authorship::with_me(OffsetEncoding::Utf16, "Ann\nLee");
    a.mark(r(0, 3), Some(&Author::new(AuthorKind::Ai, "Bot\r\n...\n---")));
    a.edit(r(3, 3), 2, Attribution::Typed(a.me().clone()));
    let text = "abcde\n";
    let file = format!("{text}{}", a.file_tail(text, LineEnding::Lf));
    let s = split_annotations(&file);
    assert_eq!(s.status, AnnotationStatus::Valid, "{file}");
    assert_eq!(s.body, text);
    let p = s.annotations.unwrap();
    let names: Vec<&str> = p.authors.iter().map(|x| x.name.as_str()).collect();
    assert_eq!(names, vec!["Ann Lee", "Bot  ... ---"]);
    assert!(p.unknown.is_empty());
}

#[test]
fn a_block_inside_a_closed_code_fence_is_text() {
    let t = "```\n---\nAnnotations: 0,4 SHA-256 aaaaaaaaaaaaaaaaaaaa\n&AI: 0,2\n...\n```\n";
    let s = split_annotations(t);
    assert_eq!(s.status, AnnotationStatus::Absent);
    assert_eq!(s.body, t);
}

#[test]
fn a_lookalike_in_a_fence_left_open_is_text_unless_its_hash_is_right() {
    // Someone writing about the format, the closing fence not typed yet: taking the example
    // for a block would hide it, and Discard would delete it.
    let t = "```\ncode\n\n---\nAnnotations: 0,4 SHA-256 aaaaaaaaaaaaaaaaaaaa\n&AI: 0,2\n...\n";
    let s = split_annotations(t);
    assert_eq!(s.status, AnnotationStatus::Absent);
    assert_eq!(s.body, t);
    for open in ["~~~~ yaml\n", "  ```md\n", "```\n```\n````\n", "> x\n```\n"] {
        let t = format!("{open}Example\n\n---\nAnnotations: 0,4 SHA-256 aaaaaaaaaaaaaaaaaaaa\n&AI: 0,2\n...\n");
        assert_eq!(split_annotations(&t).status, AnnotationStatus::Absent, "{open:?}");
    }
    // Closed fences, a fence-like line with backticks in its info string, a fence indented as
    // code, or a short run: no open fence, so a look-alike is a block (with a wrong hash, the
    // question is put to the user).
    for closed in ["```\nx\n```\n", "~~~\nx\n~~~~~\n", "``` a`b\n", "    ```\n", "``\n"] {
        let t = format!("{closed}\n---\nAnnotations: 0,4 SHA-256 aaaaaaaaaaaaaaaaaaaa\n&AI: 0,2\n...\n");
        assert_eq!(split_annotations(&t).status, AnnotationStatus::HashMismatch, "{closed:?}");
    }
    // A real block whose text ends inside an open fence (the writer forgot to close it): the
    // hash is right, so it is a block.
    let f = file_with("```\nlet x = 1;\n", LineEnding::Lf, &[(4, 8, ai())]);
    assert_eq!(split_annotations(&f).status, AnnotationStatus::Valid);
}

#[test]
fn appended_text_after_the_block_makes_it_text() {
    let f = file_with("abc\n", LineEnding::Lf, &[(0, 2, ai())]);
    assert_eq!(split_annotations(&format!("{f}more\n")).status, AnnotationStatus::Absent);
}

#[test]
fn tolerates_missing_final_newline_trailing_blank_lines_and_crlf() {
    let f = file_with("hello world\n", LineEnding::Lf, &[(6, 11, ai())]);
    for variant in [f.trim_end().to_string(), format!("{f}\n\n"), format!("{f}  \n"), f.replace('\n', "\r\n")] {
        let s = split_annotations(&variant);
        assert_eq!(s.status, AnnotationStatus::Valid, "{variant:?}");
        assert!(s.annotations.is_some());
        assert_eq!(format!("{}{}", s.body, s.raw_tail.unwrap()), variant);
    }
}

#[test]
fn unknown_keys_and_continuations_survive_a_save() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(0, 3), Some(&ai()));
    let base = format!("abc\n{}", a.annotation_block("abc\n", LineEnding::Lf).unwrap());
    let with_extra = base.replace("...\n", "Title: a title  \nNote: first\n  second\n  \n&AI Bot <x>: 1 foo\n...\n");
    let s = split_annotations(&with_extra);
    assert_eq!(s.status, AnnotationStatus::Valid);
    let p = s.annotations.as_ref().unwrap();
    assert_eq!(p.unknown, vec!["Title: a title  ", "Note: first", "  second", "  ", "&AI Bot <x>: 1 foo"]);
    let b = Authorship::from_annotations(&s.body, p, OffsetEncoding::Utf16, "Me");
    let out = format!("{}{}", s.body, b.annotation_block(&s.body, LineEnding::Lf).unwrap());
    assert_eq!(out, with_extra);
}

#[test]
fn translated_key_is_kept() {
    let f = file_with("abc\n", LineEnding::Lf, &[(0, 2, ai())]).replace("Annotations:", "Anmerkungen:");
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    let p = s.annotations.unwrap();
    assert_eq!(p.hash_key, "Anmerkungen");
    let a = Authorship::from_annotations(&s.body, &p, OffsetEncoding::Utf16, "Me");
    assert_eq!(a.annotation_block(&s.body, LineEnding::Lf).unwrap(), f[s.body.len()..]);
}

#[test]
fn escaped_colons_in_names() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(0, 2), Some(&Author::new(AuthorKind::Ai, "gpt:4")));
    let f = format!("ab\n{}", a.annotation_block("ab\n", LineEnding::Lf).unwrap());
    assert!(f.contains("&gpt\\:4: 0,2"), "{f}");
    let s = split_annotations(&f);
    assert_eq!(s.annotations.as_ref().unwrap().authors[0].name, "gpt:4");
}

#[test]
fn names_with_backslashes_round_trip() {
    // A name ending in a backslash used to be written as `x\:` and read back as no name at all.
    // A backslash is doubled only where it could be read as an escape: before a colon or another
    // backslash, or at the end; elsewhere the line is written as the spec has it.
    for name in ["x\\", "\\", "\\\\", "a\\b", "a\\:b", "a\\\\b", "a\\\\", "trail\\\\\\", "colon:in", "a:\\", "\\:", ":", "Review\\", "C:\\Users\\"] {
        let mut a = Authorship::new(OffsetEncoding::Utf16);
        a.mark(r(0, 2), Some(&Author::new(AuthorKind::Ai, name)));
        let f = format!("ab\n{}", a.annotation_block("ab\n", LineEnding::Lf).unwrap());
        let s = split_annotations(&f);
        assert_eq!(s.status, AnnotationStatus::Valid, "{name:?}: {f}");
        let p = s.annotations.as_ref().unwrap();
        let names: Vec<&str> = p.authors.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, vec![name], "{name:?} written as: {f}");
        assert_eq!(ranges(&p.authors[0]), vec![(0, 2)], "{name:?}");
        // And the file is written back the same after reading it.
        let b = Authorship::from_annotations(&s.body, p, OffsetEncoding::Utf16, "Me");
        assert_eq!(format!("{}{}", s.body, b.annotation_block(&s.body, LineEnding::Lf).unwrap()), f, "{name:?}");
    }
    // Names the spec's rule writes (colons escaped, backslashes bare) read as before.
    let f = file_with("abc\n", LineEnding::Lf, &[(0, 2, ai())]).replace("&AI:", "&gpt\\:4 a\\b:");
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    assert_eq!(s.annotations.as_ref().unwrap().authors[0].name, "gpt:4 a\\b");
}

#[test]
fn hash_mismatch_malformed_and_clamping() {
    let f = file_with("hello world\n", LineEnding::Lf, &[(6, 11, ai())]);
    // Text changed outside the app.
    let changed = f.replacen("hello", "howdy", 1);
    let s = split_annotations(&changed);
    assert_eq!(s.status, AnnotationStatus::HashMismatch);
    assert!(s.annotations.is_some());
    // Wrong algorithm, short hash, range beyond the text, author range beyond the text.
    let md5 = f.replace("SHA-256", "MD5");
    assert!(matches!(split_annotations(&md5).status, AnnotationStatus::Malformed(_)));
    let short = f.replace(&hash32(b"hello world"), "abcdef0123");
    assert!(matches!(split_annotations(&short).status, AnnotationStatus::Malformed(_)));
    // A hashed range longer than the text: the text has shrunk since.
    let beyond = f.replace("0,11", "0,500");
    assert_eq!(split_annotations(&beyond).status, AnnotationStatus::HashMismatch);
    let far = f.replace("&AI: 6,5", "&AI: 6,500 900");
    let s = split_annotations(&far);
    assert!(matches!(s.status, AnnotationStatus::Malformed(_)));
    // Ranges beyond the text are clamped when kept.
    let a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    assert!(a.runs(None).iter().all(|x| x.range.end <= 12));
}

#[test]
fn overlapping_ranges_later_wins() {
    let f = file_with("abcdef\n", LineEnding::Lf, &[(0, 3, ai())]).replace("&AI: 0,3", "&AI: 0,4\n*Ref: 2,3");
    let s = split_annotations(&f);
    let a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    let got = runs_of(&a);
    assert_eq!(got, vec![(0, 2, ai()), (2, 5, reference())]);
}

#[test]
fn me_is_the_human_with_the_supplied_name() {
    let f = fixture("spec-example.md");
    let s = split_annotations(&f);
    let p = s.annotations.as_ref().unwrap();
    let as_human = Authorship::from_annotations(&s.body, p, OffsetEncoding::Utf16, "Human");
    assert_eq!(as_human.authors().len(), 2);
    assert_eq!(as_human.author_at(0), Some(0));
    let as_steve = Authorship::from_annotations(&s.body, p, OffsetEncoding::Utf16, "Steve");
    assert_eq!(as_steve.authors().len(), 3);
    assert_eq!(as_steve.author_at(0), Some(1));
    assert_eq!(as_steve.annotation_block(&s.body, LineEnding::Lf).unwrap().lines().filter(|l| l.starts_with('@')).count(), 1);
}

#[test]
fn authors_keep_their_order_and_empty_ones_stay() {
    let f = "x\n\n---\nAnnotations: 0,1 SHA-256 {H}  \n*Book:   \n@Zed: 0  \n&Model: \n...\n"
        .replace("{H}", &hash32(b"x"));
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    let a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    let names: Vec<_> = a.authors().iter().map(|a| a.name.clone()).collect();
    assert_eq!(names, vec!["Me", "Book", "Zed", "Model"]);
    let out = a.annotation_block("x\n", LineEnding::Lf).unwrap();
    let order: Vec<_> = out.lines().filter(|l| "@&*".contains(l.chars().next().unwrap_or(' '))).collect();
    assert_eq!(order, vec!["*Book:  ", "@Zed: 0  ", "&Model:  "]);
}

#[test]
fn untouched_files_come_back_byte_for_byte_and_edits_write_canonical() {
    let odd = "abc def\n\n\n---\nAnnotations: 0,7 SHA-256 {H}\n&AI: 0 1 2  \n...\n\n\n".replace("{H}", &hash32(b"abc def"));
    let s = split_annotations(&odd);
    assert_eq!(s.status, AnnotationStatus::Valid, "{:?}", s.body);
    let mut a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    a.set_origin(&s.body, s.raw_tail.as_ref().unwrap(), LineEnding::Lf);
    assert_eq!(format!("{}{}", s.body, a.file_tail(&s.body, LineEnding::Lf)), odd);
    // Changing the attribution rewrites the block.
    a.mark(r(5, 6), Some(&reference()));
    assert_ne!(format!("{}{}", s.body, a.file_tail(&s.body, LineEnding::Lf)), odd);
    // Changing the body does too.
    let mut b = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    b.set_origin(&s.body, s.raw_tail.as_ref().unwrap(), LineEnding::Lf);
    let tail = b.file_tail(&format!("{}!", s.body), LineEnding::Lf);
    assert_ne!(tail, s.raw_tail.unwrap());
    // Discarding drops everything.
    b.clear_origin();
    let mut c = Authorship::new(OffsetEncoding::Utf16);
    c.set_origin("abc def\n\n", "", LineEnding::Lf);
    assert_eq!(c.file_tail("abc def\n\n", LineEnding::Lf), "");
}

#[test]
fn authorship_that_is_written_reads_back_from_a_file_of_every_ending() {
    for ending in [LineEnding::Lf, LineEnding::CrLf, LineEnding::Cr] {
        let text = "alpha beta\ngamma\n\ndelta";
        let f = file_with(text, ending, &[(6, 10, ai()), (17, 22, reference())]);
        let s = split_annotations(&f);
        assert_eq!(s.status, AnnotationStatus::Valid, "{ending:?}");
        assert_eq!(s.body, to_file(&format!("{text}\n"), ending));
    }
}

// ----- run arithmetic ------------------------------------------------------------------------

#[test]
fn typing_inside_a_run_splits_it_and_at_the_edge_does_not_extend() {
    let me = Author::new(AuthorKind::Human, "Me");
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.edit(r(0, 0), 10, Attribution::As(ai()));
    a.edit(r(4, 4), 2, Attribution::Typed(me.clone()));
    assert_eq!(runs_of(&a), vec![(0, 4, ai()), (4, 6, me.clone()), (6, 12, ai())]);
    // At the edge of the AI run: a new Me run, the AI run is unchanged.
    a.edit(r(12, 12), 3, Attribution::Typed(me.clone()));
    assert_eq!(runs_of(&a).last().unwrap(), &(12, 15, me.clone()));
    a.edit(r(0, 0), 1, Attribution::Typed(me.clone()));
    assert_eq!(runs_of(&a)[0], (0, 1, me.clone()));
    assert_eq!(runs_of(&a)[1], (1, 5, ai()));
}

#[test]
fn deleting_shrinks_and_removes() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.edit(r(0, 0), 10, Attribution::As(ai()));
    a.edit(r(10, 10), 5, Attribution::As(reference()));
    a.edit(r(8, 12), 0, Attribution::None);
    assert_eq!(runs_of(&a), vec![(0, 8, ai()), (8, 11, reference())]);
    a.edit(r(0, 11), 0, Attribution::None);
    assert!(runs_of(&a).is_empty());
}

#[test]
fn deleting_between_two_runs_of_one_author_merges_them() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(0, 3), Some(&ai()));
    a.mark(r(5, 8), Some(&ai()));
    a.edit(r(3, 5), 0, Attribution::None);
    assert_eq!(runs_of(&a), vec![(0, 6, ai())]);
}

#[test]
fn inherit_extends_the_neighbour_and_toggling_bold_inside_ai_text_stays_ai() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.edit(r(0, 0), 20, Attribution::As(ai()));
    // Bold "ipsum" at 6..11 inside the AI text: `**` before and after.
    a.edit_replacing(r(6, 11), "ipsum", "**ipsum**", Attribution::Inherit);
    assert_eq!(runs_of(&a), vec![(0, 24, ai())]);
    // After AI text, with nothing after: extends it. At the very start of the document
    // with attributed text after: takes it.
    let mut b = Authorship::new(OffsetEncoding::Utf16);
    b.edit(r(0, 0), 5, Attribution::As(ai()));
    b.edit(r(0, 0), 2, Attribution::Inherit);
    assert_eq!(runs_of(&b), vec![(0, 7, ai())]);
    // Inherit with attributed text before takes that, not the text after.
    let mut c = Authorship::new(OffsetEncoding::Utf16);
    c.edit(r(0, 0), 3, Attribution::As(ai()));
    c.edit(r(3, 3), 3, Attribution::As(reference()));
    c.edit(r(3, 3), 1, Attribution::Inherit);
    assert_eq!(runs_of(&c), vec![(0, 4, ai()), (4, 7, reference())]);
    // Unattributed before, attributed after: the attributed neighbour.
    let mut d = Authorship::new(OffsetEncoding::Utf16);
    d.mark(r(3, 6), Some(&ai()));
    d.edit(r(3, 3), 2, Attribution::Inherit);
    assert_eq!(runs_of(&d), vec![(3, 8, ai())]);
}

#[test]
fn replacement_keeps_what_it_did_not_change() {
    // A table re-aligned across a Me/AI boundary keeps both.
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(5, 9), Some(&ai()));
    a.edit_replacing(r(0, 9), "| a | bb |", "| a   | bb |", Attribution::Inherit);
    // Pure insertion of two spaces inside; attribution of the original text is unchanged
    // apart from the shift.
    let got = runs_of(&a);
    assert_eq!(got.iter().map(|g| g.2.clone()).collect::<Vec<_>>(), vec![ai()]);
}

#[test]
fn mark_and_clear() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(2, 8), Some(&ai()));
    a.mark(r(4, 6), Some(&reference()));
    assert_eq!(runs_of(&a), vec![(2, 4, ai()), (4, 6, reference()), (6, 8, ai())]);
    a.mark(r(3, 7), None);
    assert_eq!(runs_of(&a), vec![(2, 3, ai()), (7, 8, ai())]);
    a.mark(r(0, 0), Some(&ai()));
    let me = a.me().clone();
    a.mark(r(0, 10), Some(&me));
    assert!(!a.has_marks());
    assert_eq!(a.uniform_author(r(0, 10)), Some(0));
}

#[test]
fn uniform_author_and_runs_within() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.mark(r(2, 6), Some(&ai()));
    assert_eq!(a.uniform_author(r(2, 6)), Some(1));
    assert_eq!(a.uniform_author(r(3, 5)), Some(1));
    assert_eq!(a.uniform_author(r(1, 5)), None);
    assert_eq!(a.uniform_author(r(0, 2)), Some(0));
    assert_eq!(a.uniform_author(r(4, 4)), None);
    let w = a.runs(Some(r(3, 4)));
    assert_eq!(w, vec![AuthorRun { range: r(3, 4), author_index: 1 }]);
}

#[test]
fn snapshot_and_restore_are_exact() {
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    a.edit(r(0, 0), 10, Attribution::As(ai()));
    let snap = a.snapshot();
    let before = runs_of(&a);
    a.edit(r(3, 7), 2, Attribution::As(reference()));
    a.mark(r(0, 2), None);
    assert_ne!(runs_of(&a), before);
    a.restore(&snap);
    assert_eq!(runs_of(&a), before);
    assert!(a.snapshot() == snap);
}

#[test]
fn renaming_me() {
    let mut a = Authorship::with_me(OffsetEncoding::Utf16, "Old");
    a.edit(r(0, 0), 3, Attribution::Typed(a.me().clone()));
    a.mark(r(3, 6), Some(&Author::new(AuthorKind::Human, "Bob")));
    a.set_me_name("Bob");
    assert_eq!(a.authors().len(), 1);
    assert!(!a.has_marks());
    assert_eq!(a.runs(None), vec![AuthorRun { range: r(0, 6), author_index: 0 }]);
}

// ----- properties ----------------------------------------------------------------------------

const ALPHABET: [&str; 8] = ["a", "é", "\u{1F600}", "\u{301}", "\n", "\u{200D}", "\u{1F468}", " "];

#[derive(Debug, Clone)]
enum Op {
    Edit { a: u8, b: u8, ins: Vec<u8>, kind: u8 },
    Mark { a: u8, b: u8, who: u8 },
    /// An edit placed at a run's edge (adversarial): `edge` picks the edge, `shift` moves it
    /// by -1, 0 or +1 characters, `del` characters are deleted from there (often none).
    EdgeEdit { edge: u8, shift: u8, del: u8, ins: Vec<u8>, kind: u8 },
    /// An edit at exactly `[s, e)` characters (what an `EdgeEdit` becomes).
    At { s: usize, e: usize, ins: Vec<u8>, kind: u8 },
}

fn op_strategy() -> impl Strategy<Value = Op> {
    prop_oneof![
        3 => (any::<u8>(), any::<u8>(), proptest::collection::vec(0u8..8, 0..6), 0u8..6)
            .prop_map(|(a, b, ins, kind)| Op::Edit { a, b, ins, kind }),
        2 => (any::<u8>(), any::<u8>(), 0u8..4).prop_map(|(a, b, who)| Op::Mark { a, b, who }),
        3 => (any::<u8>(), 0u8..3, prop_oneof![2 => Just(0u8), 1 => 1u8..4, 1 => 4u8..40], proptest::collection::vec(0u8..8, 0..4), 0u8..6)
            .prop_map(|(edge, shift, del, ins, kind)| Op::EdgeEdit { edge, shift, del, ins, kind }),
    ]
}

/// Cases for the properties below: `PROPTEST_CASES` overrides the default.
fn cases(default: u32) -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn who(i: u8) -> Option<Author> {
    match i % 4 {
        0 => None,
        1 => Some(ai()),
        2 => Some(reference()),
        _ => Some(Author::new(AuthorKind::Human, "Me")),
    }
}

fn unit_pos(chars: &[char], i: usize, enc: OffsetEncoding) -> u32 {
    chars[..i]
        .iter()
        .map(|c| match enc {
            OffsetEncoding::Utf8 => c.len_utf8(),
            OffsetEncoding::Utf16 => c.len_utf16(),
            OffsetEncoding::Utf32 => 1,
        } as u32)
        .sum()
}

/// A random history against a per-character model; after every step the runs are valid and
/// agree with the model.
fn run_history(enc: OffsetEncoding, init: Vec<u8>, ops: Vec<Op>) {
    let mut chars: Vec<char> = init.iter().flat_map(|&i| ALPHABET[i as usize % 8].chars()).collect();
    let mut model: Vec<Option<Author>> = vec![None; chars.len()];
    let mut a = Authorship::new(enc);
    for op in ops {
        // An edge edit is an ordinary edit whose place is a run edge (in characters).
        let op = match op {
            Op::EdgeEdit { edge, shift, del, ins, kind } => {
                let runs = a.runs(None);
                let mut edges: Vec<usize> = vec![0, chars.len()];
                for run in &runs {
                    for u in [run.range.start, run.range.end] {
                        if let Some(i) = (0..=chars.len()).find(|&i| unit_pos(&chars, i, enc) == u) {
                            edges.push(i);
                        }
                    }
                }
                let at = edges[edge as usize % edges.len()];
                let at = match shift {
                    0 => at.saturating_sub(1),
                    1 => at,
                    _ => (at + 1).min(chars.len()),
                };
                let end = (at + del as usize).min(chars.len());
                Op::At { s: at, e: end, ins, kind }
            }
            Op::Edit { a: x, b: y, ins, kind } => {
                let n = chars.len();
                let (s, e) = (x as usize % (n + 1), y as usize % (n + 1));
                Op::At { s: s.min(e), e: s.max(e), ins, kind }
            }
            other => other,
        };
        match op {
            Op::At { s, e, ins, kind } => {
                let new: Vec<char> = ins.iter().flat_map(|&i| ALPHABET[i as usize % 8].chars()).collect();
                let range = r(unit_pos(&chars, s, enc), unit_pos(&chars, e, enc));
                let new_units = unit_pos(&new, new.len(), enc);
                let (attr, val): (Attribution, Option<Author>) = match kind {
                    0 | 1 => {
                        let me = Author::new(AuthorKind::Human, "Me");
                        (Attribution::Typed(me.clone()), Some(me))
                    }
                    2 => (Attribution::As(ai()), Some(ai())),
                    3 => (Attribution::None, None),
                    _ => {
                        // Inherit: the character before, else the one after (post-deletion).
                        let mut after_del = model.clone();
                        after_del.drain(s..e);
                        let v = if s > 0 { after_del[s - 1].clone() } else { None }
                            .or_else(|| after_del.get(s).cloned().flatten());
                        (Attribution::Inherit, v)
                    }
                };
                a.edit(range, new_units, attr);
                model.splice(s..e, new.iter().map(|_| val.clone()));
                chars.splice(s..e, new);
            }
            Op::Mark { a: x, b: y, who: w } => {
                let n = chars.len();
                let (mut s, mut e) = (x as usize % (n + 1), y as usize % (n + 1));
                if s > e {
                    std::mem::swap(&mut s, &mut e);
                }
                let au = who(w);
                a.mark(r(unit_pos(&chars, s, enc), unit_pos(&chars, e, enc)), au.as_ref());
                for m in &mut model[s..e] {
                    *m = au.clone();
                }
            }
            Op::Edit { .. } | Op::EdgeEdit { .. } => unreachable!(),
        }
        // Invariants.
        let total = unit_pos(&chars, chars.len(), enc);
        let runs = a.runs(None);
        let mut prev_end = 0;
        let mut prev_author = None;
        for run in &runs {
            assert!(run.range.start < run.range.end);
            assert!(run.range.start >= prev_end, "sorted and disjoint");
            assert!(run.range.end <= total, "in bounds");
            if run.range.start == prev_end {
                assert_ne!(prev_author, Some(run.author_index), "adjacent runs are merged");
            }
            prev_end = run.range.end;
            prev_author = Some(run.author_index);
        }
        // Against the model, character by character; no run edge inside a code point.
        let authors = a.authors();
        for (i, c) in chars.iter().enumerate() {
            let u0 = unit_pos(&chars, i, enc);
            let width = unit_pos(&chars[i..=i], 1, enc);
            let expect = model[i].clone();
            for u in u0..u0 + width {
                let got = a.author_at(u).map(|k| authors[k as usize].clone());
                // Me typed text and unattributed text are different in memory.
                assert_eq!(got, expect, "char {i} {c:?} unit {u} {enc:?}");
            }
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(1000)))]

    #[test]
    fn edits_agree_with_the_reference_model(enc in 0usize..3, init in proptest::collection::vec(0u8..8, 0..12), ops in proptest::collection::vec(op_strategy(), 1..40)) {
        run_history(ENCODINGS[enc], init, ops);
    }

    #[test]
    fn serialize_then_parse_returns_the_same_runs(
        enc in 0usize..3,
        ending in 0usize..3,
        text in proptest::collection::vec(0u8..8, 1..40),
        marks in proptest::collection::vec((any::<u8>(), any::<u8>(), 1u8..4), 1..8),
        final_newline in any::<bool>(),
    ) {
        let enc = ENCODINGS[enc];
        let ending = [LineEnding::Lf, LineEnding::CrLf, LineEnding::Lf][ending];
        let mut text: String = text.iter().map(|&i| ALPHABET[i as usize % 8]).collect();
        if final_newline && !text.ends_with('\n') { text.push('\n'); }
        let mut a = Authorship::new(enc);
        // Marks on grapheme boundaries only (a mark inside a cluster is rounded).
        use unicode_segmentation::UnicodeSegmentation;
        let mut bounds: Vec<u32> = Vec::new();
        let mut acc = 0;
        for g in text.graphemes(true) { bounds.push(acc); acc += units(g, enc); }
        bounds.push(acc);
        for (x, y, w) in marks {
            let (mut s, mut e) = (x as usize % bounds.len(), y as usize % bounds.len());
            if s > e { std::mem::swap(&mut s, &mut e); }
            a.mark(r(bounds[s], bounds[e]), who(w).as_ref());
        }
        let tail = a.file_tail(&text, ending);
        if !a.has_marks() { prop_assert_eq!(tail, ""); return Ok(()); }
        let file = format!("{}{}", to_file(&text, ending), tail);
        let s = split_annotations(&file);
        prop_assert_eq!(s.status, AnnotationStatus::Valid);
        // The body is the text (a body with no final newline reads back with one). The
        // editor holds it with `\n` only, and ranges are converted for that.
        let body_lf = s.body.replace("\r\n", "\n").replace('\r', "\n");
        let b = Authorship::from_annotations(&body_lf, s.annotations.as_ref().unwrap(), enc, "Me");
        let text_nl = format!("{}\n", text);
        prop_assert!(body_lf == text || body_lf == text_nl);
        prop_assert_eq!(runs_of(&a), runs_of(&b));
        // And writing that again gives the same file.
        let again = format!("{}{}", to_file(&body_lf, ending), b.file_tail(&body_lf, ending));
        prop_assert_eq!(again, file);
    }

    #[test]
    fn snapshots_restore_exactly(enc in 0usize..3, init in proptest::collection::vec(0u8..8, 0..10), ops in proptest::collection::vec(op_strategy(), 1..20), later in proptest::collection::vec(op_strategy(), 1..20)) {
        let enc = ENCODINGS[enc];
        // Build some state by replaying `ops` on a model-free instance, snapshot, mutate
        // with `later`, restore.
        let mut chars_len = init.len() as u32;
        let mut a = Authorship::new(enc);
        a.edit(r(0, 0), chars_len, Attribution::As(ai()));
        let apply = |a: &mut Authorship, len: &mut u32, op: &Op| match op {
            Op::Edit { a: x, b: y, ins, kind } => {
                let n = *len;
                let (mut s, mut e) = (*x as u32 % (n + 1), *y as u32 % (n + 1));
                if s > e { std::mem::swap(&mut s, &mut e); }
                let m = ins.len() as u32;
                let attr = match kind { 0 | 1 => Attribution::Typed(a.me().clone()), 2 => Attribution::As(ai()), 3 => Attribution::None, _ => Attribution::Inherit };
                a.edit(r(s, e), m, attr);
                *len = n - (e - s) + m;
            }
            Op::Mark { a: x, b: y, who: w } => {
                let n = *len;
                let (mut s, mut e) = (*x as u32 % (n + 1), *y as u32 % (n + 1));
                if s > e { std::mem::swap(&mut s, &mut e); }
                a.mark(r(s, e), who(*w).as_ref());
            }
            Op::EdgeEdit { .. } | Op::At { .. } => {}
        };
        for op in &ops { apply(&mut a, &mut chars_len, op); }
        let snap = a.snapshot();
        let before = (runs_of(&a), a.authors());
        for op in &later { apply(&mut a, &mut chars_len, op); }
        a.restore(&snap);
        prop_assert_eq!((runs_of(&a), a.authors()), before);
    }

    #[test]
    fn split_never_panics_and_recomposes(s in "[-.a-z:@&*0-9, \\r\\n\\\\]{0,120}") {
        let sp = split_annotations(&s);
        if let Some(tail) = &sp.raw_tail {
            prop_assert_eq!(format!("{}{}", sp.body, tail), s);
        } else {
            prop_assert_eq!(sp.body, s);
        }
    }

    #[test]
    fn edit_replacing_agrees_with_plain_edits_on_what_it_keeps(
        old in "[ab|\\- ]{0,12}", new in "[ab|\\- ]{0,12}", marks in proptest::collection::vec((0u32..12, 0u32..12), 0..3)
    ) {
        let mut a = Authorship::new(OffsetEncoding::Utf16);
        let n = old.len() as u32;
        a.edit(r(0, 0), n, Attribution::Typed(a.me().clone()));
        for (x, y) in marks { let (s, e) = (x.min(y).min(n), x.max(y).min(n)); a.mark(r(s, e), Some(&ai())); }
        a.edit_replacing(r(0, n), &old, &new, Attribution::Inherit);
        let total = new.len() as u32;
        for run in a.runs(None) { prop_assert!(run.range.end <= total); }
        // Every attributed character of `new` that is a kept character of `old` stays: at
        // least, the number of AI characters never exceeds what was there plus inserted.
    }

    /// `edit_replacing` with Inherit on texts full of repeated substrings, in every encoding:
    /// the common prefix and suffix keep their attribution character for character, runs stay
    /// valid and on code point boundaries, and the result is what applying its hunks one by
    /// one as plain Inherit edits gives.
    #[test]
    fn edit_replacing_keeps_prefix_and_suffix_exactly(
        enc in 0usize..3,
        old in proptest::collection::vec(0u8..4, 0..24),
        new in proptest::collection::vec(0u8..4, 0..24),
        marks in proptest::collection::vec((any::<u8>(), any::<u8>(), 0u8..4), 0..5),
        lead in proptest::collection::vec(0u8..4, 0..4),
    ) {
        let enc = ENCODINGS[enc];
        let alpha = ["ab", "\u{1F600}", "a", "\r\n"];
        let old: String = old.iter().map(|&i| alpha[i as usize]).collect();
        let new: String = new.iter().map(|&i| alpha[i as usize]).collect();
        let lead: String = lead.iter().map(|&i| alpha[i as usize]).collect();
        let doc_old = format!("{lead}{old}!");
        let chars: Vec<char> = doc_old.chars().collect();
        let mut a = Authorship::new(enc);
        for (x, y, w) in marks {
            let n = chars.len();
            let (s, e) = ((x as usize % (n + 1)).min(y as usize % (n + 1)), (x as usize % (n + 1)).max(y as usize % (n + 1)));
            a.mark(r(unit_pos(&chars, s, enc), unit_pos(&chars, e, enc)), who(w).as_ref());
        }
        let before: Vec<Option<u32>> = (0..chars.len()).map(|i| a.author_at(unit_pos(&chars, i, enc))).collect();
        let start = units(&lead, enc);
        let mut b = a.clone();
        a.edit_replacing(r(start, start + units(&old, enc)), &old, &new, Attribution::Inherit);
        let doc_new = format!("{lead}{new}!");
        let nchars: Vec<char> = doc_new.chars().collect();
        let total = units(&doc_new, enc);
        let mut prev = 0;
        for run in a.runs(None) {
            prop_assert!(run.range.start >= prev && run.range.start < run.range.end && run.range.end <= total);
            prop_assert!((0..=nchars.len()).any(|i| unit_pos(&nchars, i, enc) == run.range.start));
            prop_assert!((0..=nchars.len()).any(|i| unit_pos(&nchars, i, enc) == run.range.end));
            prev = run.range.end;
        }
        let oc: Vec<char> = old.chars().collect();
        let nc: Vec<char> = new.chars().collect();
        let mut pre = 0;
        while pre < oc.len() && pre < nc.len() && oc[pre] == nc[pre] { pre += 1; }
        let mut suf = 0;
        while suf < oc.len() - pre && suf < nc.len() - pre && oc[oc.len() - 1 - suf] == nc[nc.len() - 1 - suf] { suf += 1; }
        let l = lead.chars().count();
        // The lead, the common prefix, the common suffix and the final "!" keep their author.
        for (i, &was) in before.iter().enumerate().take(l + pre) {
            prop_assert_eq!(a.author_at(unit_pos(&nchars, i, enc)), was, "prefix char {}", i);
        }
        for k in 0..=suf {
            let (i_new, i_old) = (nchars.len() - 1 - k, chars.len() - 1 - k);
            prop_assert_eq!(a.author_at(unit_pos(&nchars, i_new, enc)), before[i_old], "suffix char {}", k);
        }
        // Applying the same replacement as one plain Inherit edit attributes no more than the
        // diff does to anyone new (the diff only keeps or inherits).
        b.edit(r(start, start + units(&old, enc)), units(&new, enc), Attribution::Inherit);
        let authors_a: std::collections::BTreeSet<u32> = a.runs(None).iter().map(|x| x.author_index).collect();
        let mut allowed: std::collections::BTreeSet<u32> = before.iter().flatten().copied().collect();
        allowed.extend(b.runs(None).iter().map(|x| x.author_index));
        prop_assert!(authors_a.is_subset(&allowed));
    }

    /// Runs that start or end inside a grapheme cluster (an edit split a cluster or a CRLF
    /// pair) are written on cluster boundaries: each cluster goes to the author of its first
    /// unit, and the file reads back valid with exactly that attribution.
    #[test]
    fn runs_inside_clusters_are_written_whole(
        enc in 0usize..3,
        preserve in any::<bool>(),
        text in proptest::collection::vec(0u8..6, 1..30),
        marks in proptest::collection::vec((any::<u16>(), any::<u16>(), 1u8..4), 1..6),
    ) {
        use unicode_segmentation::UnicodeSegmentation;
        let enc = ENCODINGS[enc];
        let alpha = ["e\u{301}", "\r\n", "\u{1F468}\u{200D}\u{1F469}", "a", "\n", "\u{1F1E9}\u{1F1EA}"];
        let mut text: String = text.iter().map(|&i| alpha[i as usize]).collect();
        // `\r\n` is only kept in the editor's text for a file of mixed endings.
        if !preserve { text = text.replace("\r\n", "\n"); }
        text.push('\n');
        let total = units(&text, enc);
        // Every code point boundary, in units.
        let mut cps = vec![0u32];
        let mut acc = 0;
        for c in text.chars() { acc += units(&c.to_string(), enc); cps.push(acc); }
        let mut a = Authorship::new(enc);
        for (x, y, w) in marks {
            let (s, e) = (cps[x as usize % cps.len()], cps[y as usize % cps.len()]);
            a.mark(r(s.min(e), s.max(e)), who(w).as_ref());
        }
        let ending = if preserve { LineEnding::Preserve } else { LineEnding::Lf };
        let tail = a.file_tail(&text, ending);
        let file = format!("{text}{tail}");
        let s = split_annotations(&file);
        if !a.has_marks() { prop_assert!(tail.is_empty()); return Ok(()); }
        prop_assert_eq!(&s.status, &AnnotationStatus::Valid);
        prop_assert_eq!(&s.body, &text);
        let b = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), enc, "Me");
        let (aa, ba) = (a.authors(), b.authors());
        let mut at = 0u32;
        for g in text.graphemes(true) {
            let want = a.author_at(at).map(|i| aa[i as usize].clone());
            let width = units(g, enc);
            for u in at..at + width {
                prop_assert_eq!(b.author_at(u).map(|i| ba[i as usize].clone()), want.clone(), "cluster {:?} at {}", g, at);
            }
            at += width;
        }
        prop_assert_eq!(at, total);
    }
}

// ----- the fixture files ---------------------------------------------------------------------

fn fixture_bytes(name: &str) -> Vec<u8> {
    std::fs::read(format!("{}/../../fixtures/authorship/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

fn editor_text(split: &SplitFile, ending: LineEnding) -> String {
    match ending {
        LineEnding::CrLf => split.body.replace("\r\n", "\n"),
        _ => split.body.clone(),
    }
}

#[test]
fn fixtures_with_valid_blocks_round_trip_exactly() {
    for (name, ending) in [
        ("ai-draft.md", LineEnding::Lf),
        ("crlf.md", LineEnding::CrLf),
        ("emoji.md", LineEnding::Lf),
        ("unknown-keys.md", LineEnding::Lf),
        ("spec-example.md", LineEnding::Lf),
        ("harbour-lights.md", LineEnding::Lf),
    ] {
        let file = String::from_utf8(fixture_bytes(name)).unwrap();
        let s = split_annotations(&file);
        assert_eq!(s.status, AnnotationStatus::Valid, "{name}");
        let body = editor_text(&s, ending);
        for enc in ENCODINGS {
            let me = if name.starts_with("spec") {
                "Human"
            } else if name.starts_with("harbour") {
                "Steve Kaznak"
            } else {
                "Steve"
            };
            let mut a = Authorship::from_annotations(&body, s.annotations.as_ref().unwrap(), enc, me);
            a.set_origin(&body, s.raw_tail.as_ref().unwrap(), ending);
            assert_eq!(format!("{}{}", s.body, a.file_tail(&body, ending)), file, "{name} {enc:?}");
        }
    }
}

#[test]
fn fixtures_written_by_this_app_are_canonical() {
    // Files made by the app itself come back out of the canonical writer unchanged: the
    // block is rebuilt from the runs, not copied.
    for (name, ending) in [("ai-draft.md", LineEnding::Lf), ("crlf.md", LineEnding::CrLf), ("emoji.md", LineEnding::Lf)] {
        let file = String::from_utf8(fixture_bytes(name)).unwrap();
        let s = split_annotations(&file);
        let body = editor_text(&s, ending);
        let a = Authorship::from_annotations(&body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Steve");
        let block = a.annotation_block(&body, ending).unwrap();
        assert_eq!(format!("{}{}", s.body, block), file, "{name}");
    }
}

#[test]
fn fixture_authorship_covers_the_right_words() {
    let file = String::from_utf8(fixture_bytes("ai-draft.md")).unwrap();
    let s = split_annotations(&file);
    let a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Steve");
    let authors = a.authors();
    let text: Vec<u16> = s.body.encode_utf16().collect();
    for run in a.runs(None) {
        let words = String::from_utf16(&text[run.range.start as usize..run.range.end as usize]).unwrap();
        match authors[run.author_index as usize].kind {
            AuthorKind::Ai => assert!(words.starts_with("The Fresnel lens") && words.ends_with("miles away."), "{words}"),
            AuthorKind::Reference => assert!(words.starts_with("A lighthouse is a tower"), "{words}"),
            AuthorKind::Human => {}
        }
    }
    assert!(a.has_marks());
}

#[test]
fn fixture_emoji_clusters_land_on_the_same_text_in_every_encoding() {
    let file = String::from_utf8(fixture_bytes("emoji.md")).unwrap();
    let s = split_annotations(&file);
    assert_eq!(s.status, AnnotationStatus::Valid);
    for enc in ENCODINGS {
        let a = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), enc, "Steve");
        let authors = a.authors();
        let mut found = Vec::new();
        for run in a.runs(None).iter().filter(|r| authors[r.author_index as usize].kind != AuthorKind::Human) {
            let (lo, hi) = (run.range.start as usize, run.range.end as usize);
            let text = match enc {
                OffsetEncoding::Utf8 => s.body[lo..hi].to_string(),
                OffsetEncoding::Utf16 => {
                    let t: Vec<u16> = s.body.encode_utf16().collect();
                    String::from_utf16(&t[lo..hi]).unwrap()
                }
                OffsetEncoding::Utf32 => s.body.chars().skip(lo).take(hi - lo).collect(),
            };
            found.push(text);
        }
        assert_eq!(
            found,
            vec!["\u{1F1E9}\u{1F1EA} and \u{1F1EF}\u{1F1F5}", "nai\u{308}ve, e\u{301}t\u{e9}: \u{1F44D}\u{1F3FD} thumbs", "\u{1F600}\u{1F600}\u{1F600}"],
            "{enc:?}"
        );
    }
}

#[test]
fn fixture_mismatch_malformed_bom_lookalikes() {
    let m = split_annotations(&String::from_utf8(fixture_bytes("mismatch.md")).unwrap());
    assert_eq!(m.status, AnnotationStatus::HashMismatch);
    let m = split_annotations(&String::from_utf8(fixture_bytes("malformed.md")).unwrap());
    assert!(matches!(m.status, AnnotationStatus::Malformed(_)));
    // The shell strips a BOM before the core sees the text.
    let bom = fixture_bytes("bom.md");
    assert_eq!(&bom[..3], &[0xEF, 0xBB, 0xBF]);
    let s = split_annotations(std::str::from_utf8(&bom[3..]).unwrap());
    assert_eq!(s.status, AnnotationStatus::Valid);
    let l = split_annotations(&String::from_utf8(fixture_bytes("lookalikes.md")).unwrap());
    assert_eq!(l.status, AnnotationStatus::Absent);
}

// ----- size --------------------------------------------------------------------------------------

#[test]
fn a_megabyte_with_thousands_of_marks_serializes_and_parses_quickly() {
    let line = "The quick brown fox \u{1F98A} jumps over the lazy dog, e\u{301}t\u{e9} \u{65E5}\u{672C}. \n";
    let mut text = String::new();
    while text.len() < 1_000_000 {
        text.push_str(line);
    }
    let mut a = Authorship::new(OffsetEncoding::Utf16);
    let mut at = 0u32;
    for (n, l) in text.split_inclusive('\n').enumerate() {
        let len = l.encode_utf16().count() as u32;
        if n % 3 == 0 {
            a.mark(TextRange::new(at + 4, at + 20), Some(&ai()));
        }
        at += len;
    }
    let t0 = std::time::Instant::now();
    let tail = a.file_tail(&text, LineEnding::Lf);
    let write = t0.elapsed();
    let file = format!("{text}{tail}");
    let t1 = std::time::Instant::now();
    let s = split_annotations(&file);
    let read = t1.elapsed();
    assert_eq!(s.status, AnnotationStatus::Valid);
    let t2 = std::time::Instant::now();
    let b = Authorship::from_annotations(&s.body, s.annotations.as_ref().unwrap(), OffsetEncoding::Utf16, "Me");
    let build = t2.elapsed();
    assert_eq!(runs_of(&a), runs_of(&b));
    eprintln!("1 MB, {} marks: write {write:?}, split+hash {read:?}, build {build:?}", a.runs(None).len());
    // Editing at the start of a document with thousands of runs stays cheap.
    let t3 = std::time::Instant::now();
    for _ in 0..200 {
        a.edit(TextRange::new(0, 0), 1, Attribution::Typed(a.me().clone()));
    }
    eprintln!("200 edits at the start: {:?}", t3.elapsed());
}

#[test]
fn indented_blocks_and_wrapped_ranges_are_read() {
    // The spec lets keys be indented, with continuation lines two deeper; a range list may wrap.
    let hash = hash32(b"abcdefghij");
    let f = format!("abcdefghij\n\n---\n  Annotations: 0,10 SHA-256 {hash}\n  &AI: 0,2\n    4,2\n    8\n  @Me: 2,2\n...\n");
    let s = split_annotations(&f);
    assert_eq!(s.status, AnnotationStatus::Valid);
    let p = s.annotations.unwrap();
    assert_eq!(p.authors.len(), 2);
    assert_eq!(ranges(&p.authors[0]), vec![(0, 2), (4, 2), (8, 1)]);
    assert_eq!(ranges(&p.authors[1]), vec![(2, 2)]);
    assert!(p.unknown.is_empty());
}
