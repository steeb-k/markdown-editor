//! Code highlighting in the editor: roles for fenced blocks, languages and `set_code_language`.
mod common;
use common::*;
use markdown_core::highlight;
use markdown_core::*;
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

fn fixture(name: &str) -> String {
    std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/code").join(name)).unwrap()
}

fn doc(text: &str) -> Document {
    Document::new(text, OffsetEncoding::Utf16)
}

/// One line per run: its range, role and text.
fn report(text: &str) -> String {
    let d = doc(text);
    let mut out = String::new();
    for h in d.code_highlights(None) {
        out.push_str(&format!(
            "{}..{} {:?} {:?}\n",
            h.range.start,
            h.range.end,
            h.role,
            slice_units(text, OffsetEncoding::Utf16, h.range)
        ));
    }
    out
}

#[test]
fn snapshots_of_the_fixtures() {
    for name in ["languages.md", "shapes.md"] {
        insta::assert_snapshot!(format!("code_{}", name.trim_end_matches(".md")), report(&fixture(name)));
    }
}

/// Runs are sorted, disjoint, in bounds, on code text only: inside one line of a fenced block and
/// never on a fence line.
fn check_highlights(d: &Document) -> usize {
    let hs = d.code_highlights(None);
    let text = d.text();
    let blocks: Vec<Block> = d.blocks().into_iter().filter(|b| b.kind == BlockKind::CodeBlock).collect();
    let mut prev_end = 0;
    for h in &hs {
        assert!(h.range.start < h.range.end && h.range.end <= d.len(), "{h:?}");
        assert!(h.range.start >= prev_end, "unsorted or overlapping at {h:?}");
        prev_end = h.range.end;
        let s = slice_units(text, d.encoding(), h.range);
        assert!(!s.contains('\n') && !s.contains('\r'), "a run spans a line end: {h:?} {s:?}");
        let b = blocks.iter().find(|b| b.range.start <= h.range.start && h.range.end <= b.range.end);
        let b = b.unwrap_or_else(|| panic!("{h:?} is not inside a code block"));
        let first_line_end = slice_units(text, d.encoding(), TextRange::new(b.range.start, b.range.end)).find('\n');
        let first_line_units = first_line_end.map(|i| d.encoding_len(&slice_units(text, d.encoding(), b.range)[..i]));
        // Not on the opening fence's line.
        if let Some(n) = first_line_units {
            assert!(h.range.start >= b.range.start + n, "{h:?} is on the opening fence");
        }
    }
    hs.len()
}

trait Len {
    fn encoding_len(&self, s: &str) -> u32;
}
impl Len for Document {
    fn encoding_len(&self, s: &str) -> u32 {
        boundaries(s, self.encoding()).last().copied().unwrap()
    }
}

#[test]
fn ranges_are_in_bounds_and_inside_their_block() {
    let mut total = 0;
    for name in ["languages.md", "shapes.md"] {
        total += check_highlights(&doc(&fixture(name)));
    }
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf32] {
        total += check_highlights(&Document::new(&fixture("shapes.md"), enc));
    }
    assert!(total > 150, "{total}");
    // The same over every CommonMark example (fences in all their odd shapes).
    let json = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json")).unwrap();
    let examples: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    for ex in &examples {
        let md = ex["markdown"].as_str().unwrap();
        check_highlights(&Document::new(md, OffsetEncoding::Utf16));
    }
}

#[test]
fn roles_of_a_rust_block() {
    let text = "```rust\n// c\nfn main() {\n    let n: u32 = 42; let s = \"x\";\n}\nstruct Point;\n```\n";
    let d = doc(text);
    let got: Vec<(CodeRole, String)> =
        d.code_highlights(None).iter().map(|h| (h.role, slice_units(text, OffsetEncoding::Utf16, h.range))).collect();
    let has = |role: CodeRole, s: &str| got.iter().any(|(r, t)| *r == role && t == s);
    assert!(has(CodeRole::Comment, "// c"), "{got:?}");
    assert!(has(CodeRole::Keyword, "fn"), "{got:?}");
    assert!(has(CodeRole::Function, "main"), "{got:?}");
    assert!(has(CodeRole::Keyword, "let"), "{got:?}");
    assert!(has(CodeRole::Keyword, "u32"), "{got:?}"); // `storage.type`: the preview colours it as a keyword
    assert!(has(CodeRole::Type, "Point"), "{got:?}");
    assert!(has(CodeRole::Number, "42"), "{got:?}");
    assert!(has(CodeRole::String, "\"x\""), "{got:?}");
}

/// The text of the preview's HTML for a block, with the scope classes of the innermost span around
/// each character.
fn html_chars(html: &str) -> Vec<(char, Vec<String>)> {
    let mut out = Vec::new();
    let mut stack: Vec<Vec<String>> = Vec::new();
    let mut rest = html;
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix("<span class=\"") {
            let end = r.find('"').unwrap();
            stack.push(r[..end].split(' ').map(str::to_owned).collect());
            rest = &r[end + 2..];
        } else if let Some(r) = rest.strip_prefix("</span>") {
            stack.pop();
            rest = r;
        } else {
            let (c, n) = if let Some(r) = rest.strip_prefix("&lt;") { ('<', rest.len() - r.len()) }
                else if let Some(r) = rest.strip_prefix("&gt;") { ('>', rest.len() - r.len()) }
                else if let Some(r) = rest.strip_prefix("&amp;") { ('&', rest.len() - r.len()) }
                else if let Some(r) = rest.strip_prefix("&quot;") { ('"', rest.len() - r.len()) }
                else { let c = rest.chars().next().unwrap(); (c, c.len_utf8()) };
            out.push((c, stack.last().cloned().unwrap_or_default()));
            rest = &rest[n..];
        }
    }
    out
}

#[test]
fn roles_follow_the_previews_classes() {
    // The editor and the preview colour the same text alike: for every character of every block of
    // the fixture, what the preview's innermost span says (a comment, a string, a keyword...) is the
    // role here, and a character the preview leaves unspanned has no run.
    let fixtures = fixture("languages.md") + &fixture("shapes.md");
    let mut blocks: Vec<(String, String)> = Vec::new();
    let mut lines = fixtures.lines();
    while let Some(l) = lines.next() {
        if let Some(info) = l.strip_prefix("```").filter(|i| !i.is_empty()) {
            let code: Vec<&str> = lines.by_ref().take_while(|l| !l.starts_with("```")).collect();
            blocks.push((info.to_owned(), code.join("\n") + "\n"));
        }
    }
    assert!(blocks.len() > 15);
    let mut checked = 0;
    for (info, code) in blocks {
        let Some(html) = highlight::highlight(&info, &code) else { continue };
        let runs = highlight::roles_until(&info, &code, None).unwrap();
        let roles: Vec<Option<CodeRole>> = {
            let mut v = vec![None; code.len()];
            for r in runs.iter() {
                v[r.start as usize..r.end as usize].fill(Some(r.role));
            }
            v
        };
        let mut at = 0;
        for (c, classes) in html_chars(&html) {
            let role = roles[at];
            at += c.len_utf8();
            if c == '\n' || classes.is_empty() {
                continue;
            }
            let has = |a: &str| classes.iter().any(|x| x == &format!("s-{a}"));
            let want = if has("comment") {
                Some(CodeRole::Comment)
            } else if has("invalid") {
                Some(CodeRole::Invalid)
            } else if has("keyword") || has("storage") {
                Some(CodeRole::Keyword)
            } else if has("constant") && !has("support") {
                Some(CodeRole::Number)
            } else if has("string") {
                Some(CodeRole::String)
            } else {
                continue;
            };
            // `string` inside which a `constant` sits is the constant's; the cases above order that.
            if want == Some(CodeRole::Keyword) && has("string") {
                continue;
            }
            assert_eq!(role, want, "{info}: {c:?} in {classes:?}");
            checked += 1;
        }
        // And the other way round: a run only where the preview has a span.
        let spanned: Vec<bool> = {
            let mut v = Vec::new();
            for (c, classes) in html_chars(&html) {
                v.extend(std::iter::repeat_n(!classes.is_empty(), c.len_utf8()));
            }
            v
        };
        for (i, r) in roles.iter().enumerate() {
            assert!(r.is_none() || spanned[i], "{info}: byte {i} has {r:?} but the preview has no span");
        }
    }
    assert!(checked > 400, "{checked}");
}

#[test]
fn a_block_without_a_known_language_has_no_runs() {
    let text = "```\nfn a() {}\n```\n\n```nosuch\nfn b() {}\n```\n\n    fn c() {}\n\n```text\nplain\n```\n";
    assert!(doc(text).code_highlights(None).is_empty());
}

#[test]
fn every_alias_and_every_listed_language_is_recognised() {
    let aliases = [
        "jsx", "mjs", "cjs", "jsonc", "json5", "docker", "fsharp", "shell", "zsh", "console", "shellscript", "c++", "cc", "hpp",
        "cxx", "objective-c", "objc", "yml", "golang", "csharp", "rust,ignore", ".rust", "{.python}", "RUST", "Rust",
    ];
    for a in aliases {
        let text = format!("```{a}\nx\n```\n");
        assert!(doc(&text).code_language_at(0).is_some(), "{a}");
    }
    // Every syntax of the binary a person can pick (not plain text, not the helper syntaxes that exist
    // only to be embedded in others) is in the list.
    let listed: Vec<&str> = highlight::languages().iter().map(|(_, d)| d.as_str()).collect();
    let set = two_face::syntax::extra_newlines();
    // These have no extension and a name that is more than one word, so no info string can name them
    // (the preview cannot either).
    let unreachable = [
        "Git Link", "LaTeX Log", "R Console", "Comma Separated Values", "Pipe Separated Values", "Semi-Colon Separated Values",
        "Dockerfile (with bash)", "Private Key",
    ];
    let mut visible = 0;
    for syntax in set.syntaxes().iter().filter(|s| !s.hidden && s.name != "Plain Text") {
        visible += 1;
        assert!(listed.contains(&syntax.name.as_str()) || unreachable.contains(&syntax.name.as_str()), "{} has no token", syntax.name);
    }
    assert_eq!(visible, listed.len() + unreachable.len());
    assert!(listed.len() > 150);
    for (token, display) in highlight::languages() {
        let d = doc(&format!("```{token}\nx\n```\n"));
        let l = d.code_language_at(0).unwrap_or_else(|| panic!("{token} is not recognised"));
        assert_eq!(&l.display, display, "{token}");
        assert_eq!(&l.name, token);
    }
}

#[test]
fn the_list_has_the_common_languages_first_then_the_rest_alphabetically() {
    let list = highlight::languages();
    assert!(list.len() > 150, "{}", list.len());
    assert_eq!(list[0], ("rust".to_owned(), "Rust".to_owned()));
    let common = highlight::common_language_count();
    assert_eq!(common, 31);
    for t in ["rust", "python", "js", "ts", "json", "sh", "cpp", "go", "swift", "sql", "md"] {
        assert!(list[..common].iter().any(|(tok, _)| tok == t), "{t} not common");
    }
    assert!(!list.iter().any(|(_, d)| d == "Plain Text"));
    // After the common block, alphabetical by display name, no repeats.
    let rest: Vec<String> = list[common..].iter().map(|(_, d)| d.to_lowercase()).collect();
    let mut sorted = rest.clone();
    sorted.sort();
    assert_eq!(rest, sorted);
    let mut names: Vec<&String> = list.iter().map(|(_, d)| d).collect();
    names.sort();
    names.dedup();
    assert_eq!(names.len(), list.len());
}

#[test]
fn the_cache_makes_a_second_query_free() {
    highlight::clear_cache();
    let code = "fn cached_probe_unique_9876() { let x = 1; }\n";
    let text = format!("```rust\n{code}```\n");
    let d = doc(&text);
    assert!(highlight::roles_cached("rust", code).is_none());
    let a = d.code_highlights(None);
    let first = highlight::roles_cached("rust", code).expect("cached after the first query");
    let bytes = highlight::cache_bytes();
    let b = d.code_highlights(None);
    assert_eq!(a, b);
    assert_eq!(highlight::cache_bytes(), bytes);
    let again = highlight::roles_until("rust", code, Some(Instant::now())).expect("a cached block is given past its deadline");
    assert!(Arc::ptr_eq(&first, &again));
    // The preview's HTML for the same block lives in the same entry and adds to it.
    highlight::highlight("rust", code).unwrap();
    assert!(highlight::cache_bytes() > bytes);
    assert!(highlight::roles_cached("rust", code).is_some());
}

#[test]
fn a_block_over_the_limits_is_plain() {
    let big = "let a = 1;\n".repeat(20_000); // 220 KB
    assert!(doc(&format!("```rust\n{big}```\n")).code_highlights(None).is_empty());
    let long = format!("let s = \"{}\";\n", "x".repeat(1_200));
    assert!(doc(&format!("```rust\n{long}```\n")).code_highlights(None).is_empty());
    // The same text under the limits is coloured.
    assert!(!doc("```rust\nlet a = 1;\n```\n").code_highlights(None).is_empty());
}

#[test]
fn a_block_that_misses_the_budget_is_plain_never_partial() {
    // Past its deadline a block gives nothing and leaves nothing in the cache.
    highlight::clear_cache();
    let code = "fn budget_probe_unique_4321() {\n    let x = 1;\n}\n";
    assert!(highlight::roles_until("rust", code, Some(Instant::now())).is_none());
    assert!(highlight::roles_cached("rust", code).is_none());
    // A block too costly for one query (thirty thousand short lines) is plain; its neighbours are not.
    let small = "```rust\nlet a = 1;\n```\n\n";
    let lines = "a\n".repeat(30_000);
    let text = format!("{small}```rust\n{lines}```\n\n{small}");
    let d = doc(&text);
    let hs = d.code_highlights(None);
    assert!(!hs.is_empty());
    let big_start = text.find("a\na\n").unwrap() as u32;
    assert!(hs.iter().all(|h| h.range.end <= 24 || h.range.start < big_start || h.range.start > big_start + 60_000), "{hs:?}");
    assert!(hs.iter().any(|h| h.range.start > big_start + 60_000));
}

#[test]
fn highlights_are_clipped_to_the_window() {
    let text = fixture("shapes.md");
    let d = doc(&text);
    let all = d.code_highlights(None);
    let at = text.find("let in_list").unwrap() as u32;
    let window = TextRange::new(at, at + 30);
    let part = d.code_highlights(Some(window));
    assert!(!part.is_empty());
    for h in &part {
        assert!(h.range.start >= window.start && h.range.end <= window.end, "{h:?}");
        assert!(all.iter().any(|a| a.role == h.role && a.range.start <= h.range.start && h.range.end <= a.range.end));
    }
    // Outside any block: nothing.
    assert!(d.code_highlights(Some(TextRange::new(0, 5))).is_empty());
}

#[test]
fn an_edit_inside_a_block_changes_runs_the_dirty_range_does_not_name() {
    let mut d = doc("```rust\nlet a = 1;\nlet b = 2;\n```\n");
    let before = d.code_highlights(None);
    // Make the first line a comment: the second line's runs do not change, but the first's do.
    let up = d.replace(TextRange::new(8, 8), "// ").unwrap();
    let ext = d.code_extent(up.dirty);
    assert!(ext.start <= 8 && ext.end >= d.len() - 5, "{ext:?} for {} units", d.len());
    let after = d.code_highlights(Some(ext));
    assert_ne!(before, after);
    // The whole block is within the extent whatever the edit touched.
    let tail = d.code_extent(TextRange::new(20, 20));
    assert_eq!(tail.start, 0);
    // Nothing to widen outside a block.
    let plain = doc("text\n\n```rust\nlet a = 1;\n```\n");
    assert_eq!(plain.code_extent(TextRange::new(1, 2)), TextRange::new(1, 2));
}

#[test]
fn the_language_under_a_position() {
    let text = "intro\n\n```rust,ignore\nfn a() {}\n```\n\n```nope\nx\n```\n\n```\ny\n```\n\n    z\n";
    let d = doc(text);
    assert!(d.code_language_at(2).is_none());
    for off in [7, 10, 25, 30] {
        let l = d.code_language_at(off).unwrap_or_else(|| panic!("{off}"));
        assert_eq!((l.name.as_str(), l.display.as_str()), ("rust", "Rust"));
        assert_eq!(slice_units(text, OffsetEncoding::Utf16, l.info_range), "rust");
        assert_eq!(slice_units(text, OffsetEncoding::Utf16, l.block), "```rust,ignore\nfn a() {}\n```");
    }
    assert!(d.code_language_at(text.find("nope").unwrap() as u32).is_none());
    assert!(d.code_language_at(text.find("y\n").unwrap() as u32).is_none());
    assert!(d.code_language_at(text.find("z").unwrap() as u32).is_none());
    assert_eq!(d.code_languages(None).len(), 1);
}

#[test]
fn set_code_language_round_trips_for_every_listed_token() {
    for (token, display) in highlight::languages() {
        for (src, rest) in [("```rust,ignore\nlet a = 1;\n```\n", ",ignore"), ("```text\nx\n```\n", ""), ("```\nx\n```\n", "")] {
            let d = doc(src);
            let block = d.blocks().into_iter().find(|b| b.kind == BlockKind::CodeBlock).unwrap().range;
            let edit = d.set_code_language(block, token).unwrap_or_else(|| panic!("{token}"));
            let mut d2 = doc(src);
            d2.replace(edit.range, &edit.replacement).unwrap();
            assert_eq!(d2.text(), format!("```{token}{rest}\n{}", &src[src.find('\n').unwrap() + 1..]), "{token}");
            let l = d2.code_language_at(0).unwrap_or_else(|| panic!("{token} is not read back"));
            assert_eq!(&l.display, display);
            assert_eq!(d2.blocks().iter().filter(|b| b.kind == BlockKind::CodeBlock).count(), 1);
        }
    }
}

#[test]
fn set_code_language_keeps_what_follows_the_word() {
    let cases = [
        ("```python {.numberLines}\nx\n```", "```rust {.numberLines}\nx\n```"),
        ("``` {.python .numberLines}\nx\n```", "``` {.rust .numberLines}\nx\n```"),
        ("```.js title=a.js\nx\n```", "```.rust title=a.js\nx\n```"),
        ("~~~sh\nx\n~~~", "~~~rust\nx\n~~~"),
        ("> ```sh\n> x\n> ```", "> ```rust\n> x\n> ```"),
        ("- a\n\n  ```sh -e\n  x\n  ```", "- a\n\n  ```rust -e\n  x\n  ```"),
        ("```nosuchlang\nx\n```", "```rust\nx\n```"),
    ];
    for (src, want) in cases {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let mut d = Document::new(src, enc);
            let block = d.blocks().into_iter().find(|b| b.kind == BlockKind::CodeBlock).unwrap().range;
            let edit = d.set_code_language(block, "rust").unwrap_or_else(|| panic!("{src:?}"));
            d.replace(edit.range, &edit.replacement).unwrap();
            assert_eq!(d.text(), want);
            assert_eq!(edit.selection.start, edit.range.start + d.encoding_len("rust"));
        }
    }
}

#[test]
fn set_code_language_in_a_document_with_wide_text_before_it() {
    let src = "🎉 héllo 𝄞\n\n```sh\nx='🎉' # c\n```\n";
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let mut d = Document::new(src, enc);
        let block = d.blocks().into_iter().find(|b| b.kind == BlockKind::CodeBlock).unwrap().range;
        let edit = d.set_code_language(block, "python").unwrap();
        d.replace(edit.range, &edit.replacement).unwrap();
        assert_eq!(d.text(), "🎉 héllo 𝄞\n\n```python\nx='🎉' # c\n```\n");
        let hs = d.code_highlights(None);
        assert!(!hs.is_empty());
        for h in hs {
            let s = slice_units(d.text(), enc, h.range);
            assert!(!s.contains('\n') && !s.is_empty());
        }
    }
}

#[test]
fn set_code_language_refuses_what_is_not_a_fenced_block_or_one_word() {
    let d = doc("    indented\n\n```rust\nx\n```\n\npara\n");
    let blocks = d.blocks();
    let indented = blocks.iter().find(|b| b.kind == BlockKind::CodeBlock).unwrap().range;
    assert!(d.set_code_language(indented, "rust").is_none());
    let fenced = blocks.iter().filter(|b| b.kind == BlockKind::CodeBlock).nth(1).unwrap().range;
    for bad in ["", "two words", "a,b", "{x}", "ru`st", "...", "a\nb"] {
        assert!(d.set_code_language(fenced, bad).is_none(), "{bad:?}");
    }
    assert!(d.set_code_language(TextRange::new(2, 5), "rust").is_none());
    assert!(d.set_code_language(fenced, "rust").is_some());
}

#[test]
fn crlf_blocks_are_highlighted_like_lf_ones() {
    let lf = "```rust\nlet a = 1; // c\n\nlet b = \"s\";\n```\n";
    let crlf = lf.replace('\n', "\r\n");
    let texts = |t: &str| -> Vec<(CodeRole, String)> {
        doc(t).code_highlights(None).iter().map(|h| (h.role, slice_units(t, OffsetEncoding::Utf16, h.range))).collect()
    };
    assert_eq!(texts(lf), texts(&crlf));
    assert!(!texts(lf).is_empty());
}

/// The role of every UTF-16 unit of `d` (`None`: plain).
fn roles_per_unit(d: &Document) -> Vec<Option<CodeRole>> {
    let mut out = vec![None; d.len() as usize];
    for h in d.code_highlights(None) {
        for u in h.range.start..h.range.end {
            out[u as usize] = Some(h.role);
        }
    }
    out
}

#[test]
fn fences_in_containers_unclosed_with_attributes_and_tildes() {
    let cases: [(&str, &str, CodeRole); 8] = [
        ("- item\n\n  ```rust\n  let in_list = 1; // c\n  ```\n", "// c", CodeRole::Comment),
        ("1. one\n   - two\n\n     ```python\n     x = 'deep'\n     ```\n", "'deep'", CodeRole::String),
        ("> ```js\n> var q = 'quoted';\n> ```\n", "'quoted'", CodeRole::String),
        ("> - a\n>\n>   ```rust\n>   let n = 7;\n>   ```\n", "7", CodeRole::Number),
        ("```rust\nfn never_closed() {}\n// still code\n", "// still code", CodeRole::Comment),
        ("```rust {.numberLines startFrom=\"3\"}\nlet a = \"attr\";\n```\n", "\"attr\"", CodeRole::String),
        ("~~~python\n# tilde comment\n~~~\n", "# tilde comment", CodeRole::Comment),
        ("```` rust\nlet s = \"four ticks\";\n````\n", "\"four ticks\"", CodeRole::String),
    ];
    for (text, needle, role) in cases {
        for t in [text.to_owned(), text.replace('\n', "\r\n")] {
            let d = doc(&t);
            check_highlights(&d);
            let at = t.find(needle).unwrap() as u32;
            let hs = d.code_highlights(None);
            let h = hs.iter().find(|h| h.range.start <= at && at < h.range.end).unwrap_or_else(|| panic!("{t:?}: {needle} is plain: {hs:?}"));
            assert_eq!(h.role, role, "{t:?}");
            // The container's prefix (blanks and `>` at a line's start) is never coloured.
            let mut line_start = 0;
            for line in t.split_inclusive('\n') {
                let prefix = line.len() - line.trim_start_matches([' ', '>']).len();
                for i in line_start..line_start + prefix {
                    assert!(!hs.iter().any(|h| h.range.start <= i as u32 && (i as u32) < h.range.end), "{t:?}: prefix at {i}");
                }
                line_start += line.len();
            }
            assert_eq!(d.code_languages(None).len(), 1, "{t:?}");
        }
    }
    // The line over the limit: the whole block is plain, the block beside it is not.
    let long = format!("```rust\nlet a = 1;\nlet s = \"{}\";\n```\n\n```rust\nlet b = 2;\n```\n", "y".repeat(1_001));
    let d = doc(&long);
    let hs = d.code_highlights(None);
    let second = long.rfind("let b").unwrap() as u32;
    assert!(!hs.is_empty() && hs.iter().all(|h| h.range.start >= second), "{hs:?}");
    // A language the highlighter does not know: no badge, no runs.
    let d = doc("```klingon\nqapla'\n```\n");
    assert!(d.code_highlights(None).is_empty() && d.code_languages(None).is_empty());
}

#[test]
fn opening_a_block_comment_recolours_the_rest_of_the_block_within_the_extent() {
    let text = "intro\n\n```rust\nlet a = 1;\nlet b = \"s\";\nfn c() {}\n```\n\nafter\n";
    let mut d = doc(text);
    let at = text.find("let a").unwrap() as u32;
    // `//` first: only that line changes.
    let up = d.replace(TextRange::new(at, at), "//").unwrap();
    let ext = d.code_extent(up.dirty);
    let block = d.blocks().into_iter().find(|b| b.kind == BlockKind::CodeBlock).unwrap().range;
    assert!(ext.start <= block.start && ext.end >= block.end, "{ext:?} {block:?}");
    // Then `/*`: every line after it is a comment now, far outside the line the edit touched.
    let up = d.replace(TextRange::new(at + 1, at + 2), "*").unwrap();
    assert!(up.dirty.end < block.end, "the dirty range names the edited line only: {:?}", up.dirty);
    let ext = d.code_extent(up.dirty);
    assert!(ext.start <= block.start && ext.end >= block.end - 3, "{ext:?}");
    let new_text = d.text().to_owned();
    let fn_at = new_text.find("fn c").unwrap() as u32;
    let hs = d.code_highlights(Some(ext));
    let fn_role = hs.iter().find(|h| h.range.start <= fn_at && fn_at < h.range.end).map(|h| h.role);
    assert_eq!(fn_role, Some(CodeRole::Comment), "{hs:?}");
    // And back.
    let up = d.replace(TextRange::new(at, at + 2), "").unwrap();
    let ext = d.code_extent(up.dirty);
    let fn_at = d.text().find("fn c").unwrap() as u32;
    let hs = d.code_highlights(Some(ext));
    assert_eq!(hs.iter().find(|h| h.range.start <= fn_at && fn_at < h.range.end).map(|h| h.role), Some(CodeRole::Keyword));
}

/// What the shell does after every edit: restyle `code_extent(dirty)` (it also widens to paragraphs,
/// which only adds). Outside that extent every unit's role must be what it was before the edit (so the
/// stored colours there are still right), and inside it what a fresh document says.
#[test]
fn restyling_the_code_extent_of_every_edit_leaves_nothing_stale() {
    let pieces = [
        "```rust\nlet a = 1; // c\nfn f() {}\n```\n",
        "~~~python\nx = 'a' # c\n~~~\n",
        "> ```js\n> var a = 'q';\n> ```\n",
        "- item\n\n  ```sh\n  echo \"$HOME\" # c\n  ```\n",
        "```rust\n/* open\nlet b = 2;\n",
        "plain *prose* line\n",
        "\n",
        "```c {.attr}\nint main() { return 0; }\n```\n",
        "    indented code\n",
        "```\nno language\n```\n",
    ];
    let inserts = ["/*", "*/", "//", "```", "~~~", "\n", "\"", "'", "`", "rust", "> ", "- ", "x", "", "  ", "#"];
    let mut seed: u64 = 0x2545_F491_4F6C_DD1D;
    let mut next = |n: usize| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        (seed % n as u64) as usize
    };
    for case in 0..1500 {
        let count = 2 + next(6);
        let text: String = (0..count).map(|_| pieces[next(pieces.len())]).collect::<Vec<_>>().join("\n");
        for crlf in [false, true] {
            let text = if crlf { text.replace('\n', "\r\n") } else { text.clone() };
            let mut d = doc(&text);
            let before = roles_per_unit(&d);
            let len = d.len() as usize;
            let mut start = next(len + 1);
            // Never between a CR and its LF.
            if crlf && start > 0 && start < len && text.as_bytes()[start - 1] == b'\r' {
                start -= 1;
            }
            let mut end = (start + next(4)).min(len);
            if crlf && end > 0 && end < len && text.as_bytes()[end - 1] == b'\r' {
                end -= 1;
            }
            let ins = inserts[next(inserts.len())];
            let up = d.replace(TextRange::new(start as u32, end as u32), ins).unwrap();
            let ext = d.code_extent(up.dirty);
            let fresh = doc(d.text());
            assert_eq!(d.code_highlights(None), fresh.code_highlights(None), "case {case}: incremental differs from fresh for {:?}", d.text());
            let after = roles_per_unit(&fresh);
            let delta = ins.len() as isize - (end - start) as isize;
            for (u, role) in after.iter().enumerate() {
                if (u as u32) >= ext.start && (u as u32) < ext.end {
                    continue;
                }
                let old = if u < start { u } else { (u as isize - delta) as usize };
                assert!(
                    u < start || u >= start + ins.len(),
                    "case {case}: the inserted text at {u} is outside the extent {ext:?} (dirty {:?})",
                    up.dirty
                );
                assert_eq!(
                    *role, before[old],
                    "case {case}: unit {u} changed role outside the extent {ext:?} (dirty {:?}) after {:?} at {start}..{end} in {text:?}",
                    up.dirty, ins
                );
            }
        }
    }
}

// ----- themes -----------------------------------------------------------------------------------

#[test]
fn builtin_themes_carry_the_syntax_table() {
    let light = syntax_palette(false);
    let dark = syntax_palette(true);
    let themes = builtin_themes();
    assert_eq!(themes[0].syntax, light);
    assert_eq!(themes[1].syntax, dark);
    assert_eq!(themes[2].syntax, light); // sepia: the light colours read on its code background
    for t in &themes {
        for (name, c) in t.syntax.all() {
            assert!(contrast_ratio(c, t.colors.code_background) >= 4.5, "{} {name}", t.id);
            assert!(contrast_ratio(c, t.colors.background) >= 4.5, "{} {name} on the page", t.id);
        }
    }
}

const BARE: &str = r##"
id = "bare" 
name = "Bare"
is_dark = IS_DARK
[colors]
background = "BG"
text = "#26282B"
markup = "#A3A5A9"
heading = "#111214"
link = "#1859C9"
code_text = "#5B3A8C"
code_background = "#F0F0EC"
quote = "#585D66"
selection = "#CCE0FF"
caret = "#1E78F0"
focus_dim = "#B9BBBF"
pos_noun = "#9A4700"
pos_verb = "#B02A22"
pos_adjective = "#0A6A9E"
pos_adverb = "#7A3A9E"
pos_conjunction = "#17783A"
author_ai = "#6C47B8"
author_reference = "#8A5F00"
rule = "#D9DADD"
table_border = "#C9CBCF"
"##;

#[test]
fn a_theme_without_the_table_falls_back_by_its_background() {
    let light = Theme::from_toml(&BARE.replace("IS_DARK", "false").replace("BG", "#FBFBF9")).unwrap();
    assert_eq!(light.syntax, syntax_palette(false));
    let dark = Theme::from_toml(&BARE.replace("IS_DARK", "true").replace("BG", "#1B1C1E")).unwrap();
    assert_eq!(dark.syntax, syntax_palette(true));
}

#[test]
fn a_custom_syntax_table_reaches_the_preview() {
    let src = BARE.replace("IS_DARK", "false").replace("BG", "#FBFBF9")
        + "\n[syntax]\ncomment = \"#111111\"\nkeyword = \"#123456\"\nstring = \"#222222\"\nnumber = \"#333333\"\nfunction = \"#444444\"\ntype = \"#555555\"\ntag = \"#666666\"\nvariable = \"#777777\"\n";
    let t = Theme::from_toml(&src).unwrap();
    assert_eq!(t.syntax.keyword, Color::from_hex("#123456").unwrap());
    let css = preview_css(&t, &Typography::default());
    assert!(css.contains("--tok-keyword: #123456;"), "{css}");
    // A table with a missing or unknown colour is an error, not a half palette.
    assert!(Theme::from_toml(&src.replace("keyword = \"#123456\"\n", "")).is_err());
    assert!(Theme::from_toml(&src.replace("[syntax]\n", "[syntax]\nextra = \"#000000\"\n")).is_err());
}

// ----- performance ------------------------------------------------------------------------------

fn rust_block(i: usize, lines: usize) -> String {
    // About 45 bytes a line, as ordinary Rust runs.
    let mut s = format!("// helper {i}\npub fn compute_{i}(input: &[u32]) -> Vec<String> {{\n");
    let mut n = 0;
    while s.lines().count() < lines - 2 {
        s.push_str(&format!("    let v{n} = input[{n}] as f64 * {}.5; // {n}\n", n * 7 + i));
        n += 1;
    }
    s.push_str("    vec![String::new()]\n}\n");
    s
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

/// Typing at 1 MB with 200 code blocks, and inside a 2 000-line block of Rust (release:
/// `cargo test --release --test code -- --ignored --nocapture`).
#[test]
#[ignore]
fn highlight_cost_at_one_megabyte_and_in_a_big_block() {
    highlight::warm_up();
    let prose = "Ordinary prose with *emphasis*, **strong** words, `code` and a [link](https://example.com) for the styler. ".repeat(20);
    let mut text = String::new();
    let mut i = 0;
    while text.len() < 1 << 20 {
        text.push_str(&format!("## Section {i}\n\n{prose}\n\n```rust\n{}```\n\n{prose}\n\nMARKER{i}\n\n", rust_block(i, 24)));
        i += 1;
        if i == 200 {
            break;
        }
    }
    let mut d = doc(&text);
    println!("{} KB, {} blocks", text.len() / 1024, i);
    highlight::clear_cache();
    let t = Instant::now();
    let n = d.code_highlights(None).len();
    println!("all blocks, cold: {:.1} ms for {n} runs (one query; budget applies)", t.elapsed().as_secs_f64() * 1e3);
    let t = Instant::now();
    d.code_highlights(None);
    println!("all blocks, warm: {:.1} ms; cache {} KB", t.elapsed().as_secs_f64() * 1e3, highlight::cache_bytes() / 1024);
    // Typing outside the blocks, then inside one.
    for (name, marker) in [("in prose", "MARKER100"), ("in a block", "let v3 = input")] {
        let (mut replace_ms, mut query_ms) = (vec![], vec![]);
        let start = text.find(marker).unwrap() as u32 + 3;
        for at in start..start + 40 {
            let t = Instant::now();
            let up = d.replace(TextRange::new(at, at), "x").unwrap();
            replace_ms.push(t.elapsed().as_secs_f64() * 1e3);
            let t = Instant::now();
            let ext = d.code_extent(up.dirty);
            let _ = d.code_highlights(Some(ext));
            let _ = d.code_languages(Some(ext));
            query_ms.push(t.elapsed().as_secs_f64() * 1e3);
        }
        println!("typing {name}: replace {:.1} ms, code query {:.2} ms (median of 40)", median(replace_ms), median(query_ms));
    }
    // A 2 000-line block.
    let big = rust_block(7, 2000);
    let text = format!("# Big\n\n```rust\n{big}```\n\nAfter.\n");
    let mut d = doc(&text);
    println!("big block: {} KB, 2000 lines", big.len() / 1024);
    for _ in 0..3 {
        highlight::clear_cache();
        let t = Instant::now();
        highlight::roles_until("rust", &big, None).unwrap();
        println!("big block, no deadline: {:.1} ms", t.elapsed().as_secs_f64() * 1e3);
    }
    highlight::clear_cache();
    let t = Instant::now();
    let n = d.code_highlights(None).len();
    println!("big block, cold: {:.1} ms ({n} runs)", t.elapsed().as_secs_f64() * 1e3);
    let start = text.find("let v3 = input").unwrap() as u32 + 3;
    let (mut replace_ms, mut query_ms) = (vec![], vec![]);
    for at in start..start + 20 {
        let t = Instant::now();
        let up = d.replace(TextRange::new(at, at), "x").unwrap();
        replace_ms.push(t.elapsed().as_secs_f64() * 1e3);
        let t = Instant::now();
        let ext = d.code_extent(up.dirty);
        let hs = d.code_highlights(Some(ext));
        query_ms.push(t.elapsed().as_secs_f64() * 1e3);
        if hs.is_empty() {
            println!("  (the block went plain: its highlighting missed the budget)");
        }
    }
    println!(
        "typing in the big block: replace {:.1} ms, code query {:.1} ms (median of 20, a cache miss each); cache {} KB",
        median(replace_ms),
        median(query_ms),
        highlight::cache_bytes() / 1024
    );
}

#[test]
fn a_lone_cr_ends_a_line_for_the_runs_too() {
    // Found by tests/fuzz.rs: a string token opened on one line ran over a bare `\r` (the core reads `\r` as a
    // line end, the highlighter was handed the block split on `\n` only).
    for text in ["~~~rust\n\u{1F389}\n!:\rRequest and Response\n~~~\n", "```rust\nlet a = \"x\rlet b = 1;\n```\n", "```rust\r\nlet a = \"x\r\nlet b = 1;\r\n```\r\n"] {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let d = Document::new(text, enc);
            for h in d.code_highlights(None) {
                let s = slice_units(d.text(), enc, h.range);
                assert!(!s.contains(['\n', '\r']), "{text:?}: {h:?} {s:?}");
            }
            check_highlights(&d);
        }
    }
    // A comment ends at a lone `\r` as it does at `\n`.
    let lf = doc("```rust\nlet a = 1; // c\nlet b = \"s\";\n```\n");
    let cr = doc("```rust\nlet a = 1; // c\rlet b = \"s\";\n```\n");
    let on = |d: &Document| d.code_highlights(None).iter().map(|h| (slice_units(d.text(), d.encoding(), h.range), h.role)).collect::<Vec<_>>();
    assert_eq!(on(&lf), on(&cr));
}
