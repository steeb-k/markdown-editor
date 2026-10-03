//! The renderer against pulldown-cmark's own HTML writer (`html::push_html`), on every CommonMark
//! example, the fixtures, the oracle's regressions and random token soup. Our additions are
//! normalised away, each by a rule below; any other difference fails with the input.
//!
//! The additions: heading `id`s; task items' class and the checkbox's spelling and place (in the
//! paragraph of a loose item); bare URLs as links; footnotes numbered by first reference and
//! collected at the end (their bodies are compared one by one, by name). Front matter is dropped
//! by both. `data-line` and highlighting are off here (`source_lines: false, highlight: false`).
mod common;
use common::*;
use markdown_core::*;
use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

fn pulldown_html(md: &str) -> Option<String> {
    use pulldown_cmark::Options as O;
    let o = O::ENABLE_TABLES | O::ENABLE_FOOTNOTES | O::ENABLE_STRIKETHROUGH | O::ENABLE_TASKLISTS | O::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    catch_unwind(AssertUnwindSafe(|| {
        let mut s = String::new();
        pulldown_cmark::html::push_html(&mut s, pulldown_cmark::Parser::new_ext(md, o));
        s
    }))
    .ok()
}

fn ours(md: &str) -> String {
    Document::new(md, OffsetEncoding::Utf8).render_html(&RenderOptions { highlight: false, ..Default::default() })
}

/// Removes every `<open ...>...</close>` piece (no nesting of the same element) and gives the
/// removed pieces.
fn cut(html: &str, open: &str, close: &str) -> (String, Vec<String>) {
    let mut out = String::new();
    let mut pieces = Vec::new();
    let mut rest = html;
    while let Some(i) = rest.find(open) {
        out.push_str(&rest[..i]);
        let after = &rest[i..];
        let Some(e) = after.find(close) else {
            rest = after;
            break;
        };
        pieces.push(after[..e + close.len()].to_owned());
        rest = &after[e + close.len()..];
    }
    out.push_str(rest);
    (out, pieces)
}

/// Task items' class and checkboxes, and the newline after an item's start tag (pulldown writes
/// none before a nested block after a checkbox or a note defined in the item; we do): whitespace.
fn normalise_tasks(html: &str) -> String {
    html.replace("<li class=\"task-list-item\">", "<li>")
        .replace("<input disabled=\"\" type=\"checkbox\" checked=\"\" /> \n", "\n")
        .replace("<input disabled=\"\" type=\"checkbox\" /> \n", "\n")
        .replace("<input disabled=\"\" type=\"checkbox\" checked=\"\" /> ", "")
        .replace("<input disabled=\"\" type=\"checkbox\" /> ", "")
        .replace("<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\n", "")
        .replace("<input disabled=\"\" type=\"checkbox\"/>\n", "")
}

/// Links whose text is their own address (`http://`, `https://` or `www.`), unwrapped to the
/// text, on both sides: ours finds bare URLs (pulldown leaves them as text), and pulldown's own
/// `<http://...>` autolinks look the same. (`bare_urls_agree_with_the_analysis` checks which text
/// we link.)
fn unlink_bare_urls(html: &str, _md: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(i) = rest.find("<a href=\"") {
        out.push_str(&rest[..i]);
        let after = &rest[i + 9..];
        let (Some(q), Some(close)) = (after.find("\">"), after.find("</a>")) else {
            out.push_str(&rest[i..i + 9]);
            rest = after;
            continue;
        };
        let (href, label) = (&after[..q], after.get(q + 2..close).unwrap_or(""));
        let lower = label.to_ascii_lowercase();
        let urlish = lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("www.");
        if q < close && urlish && !label.contains('<') && (href.contains(&label.replace("&amp;", "&")[..label.len().min(4)])) {
            out.push_str(label);
            rest = &after[close + 4..];
        } else {
            out.push_str(&rest[i..i + 9]);
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

/// Heading ids (ours only; raw HTML's own ids stay).
fn strip_heading_ids(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(i) = rest.find("<h") {
        let after = &rest[i + 2..];
        out.push_str(&rest[..i + 2]);
        let b = after.as_bytes();
        if b.first().is_some_and(u8::is_ascii_digit) && after[1..].starts_with(" id=\"") {
            out.push(b[0] as char);
            let skip = after[6..].find('"').map_or(after.len(), |q| 6 + q + 1);
            rest = &after[skip..];
        } else {
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

/// Footnote bodies by name, and the HTML without the footnotes.
fn split_footnotes_pulldown(html: &str) -> Option<(String, BTreeMap<String, String>)> {
    let (html, _) = cut(html, "<sup class=\"footnote-reference\">", "</sup>");
    let mut bodies = BTreeMap::new();
    let mut out = String::new();
    let mut rest = html.as_str();
    let open = "<div class=\"footnote-definition\" id=\"";
    while let Some(i) = rest.find(open) {
        out.push_str(&rest[..i]);
        // pulldown starts a definition on a new line; after an opening tag or text (a note
        // defined inside a list item) that newline is the definition's, not the item's.
        if out.ends_with('\n') && (out.ends_with("<li>\n") || !out[..out.len() - 1].ends_with('>')) {
            out.pop();
        }
        let after = &rest[i + open.len()..];
        let q = after.find('"')?;
        let name = after[..q].to_owned();
        let label_end = after.find("</sup>")? + "</sup>".len();
        // The definition ends at the matching `</div>`.
        let body_from = label_end;
        let mut depth = 1;
        let mut k = body_from;
        loop {
            let next_open = after[k..].find("<div");
            let next_close = after[k..].find("</div>")?;
            match next_open {
                Some(o) if o < next_close => {
                    depth += 1;
                    k += o + 4;
                }
                _ => {
                    depth -= 1;
                    if depth == 0 {
                        // A body that was only references is an empty paragraph once they are cut.
                        let body = after[body_from..k + next_close].replace("<p></p>\n", "").replace("<p></p>", "").trim().to_owned();
                        bodies.entry(name.clone()).or_insert(body);
                        rest = &after[k + next_close + "</div>".len()..];
                        rest = rest.strip_prefix('\n').unwrap_or(rest);
                        break;
                    }
                    k += next_close + 6;
                }
            }
        }
    }
    out.push_str(rest);
    Some((out, bodies))
}

fn split_footnotes_ours(html: &str) -> (String, BTreeMap<String, String>) {
    let (html, _) = cut(html, "<sup class=\"footnote-ref\"", "</sup>");
    let (html, sections) = cut(&html, "<section class=\"footnotes\">", "</section>\n");
    let mut bodies = BTreeMap::new();
    for s in sections {
        let mut rest = s.as_str();
        while let Some(i) = rest.find("<li id=\"fn-") {
            let after = &rest[i + "<li id=\"fn-".len()..];
            let q = after.find('"').unwrap();
            let name = after[..q].to_owned();
            let body_start = after.find(">\n").unwrap() + 2;
            let end = after.find("</li>\n<li id=\"fn-").or_else(|| after.rfind("</li>\n</ol>")).unwrap();
            let body = &after[body_start..end];
            let (body, _) = cut(body, " <a href=\"#fnref-", "</a>");
            let (body, _) = cut(&body, "<a href=\"#fnref-", "</a>");
            let body = body.replace("<p></p>\n", "");
            bodies.insert(name, body.trim().to_owned());
            rest = &after[end..];
        }
    }
    (html, bodies)
}

/// Unescapes the few entities pulldown uses in a footnote's `id` (ours is the name, escaped the same way).
#[derive(Default, Debug)]
struct Tally {
    compared: usize,
    equal: usize,
    with_footnotes: usize,
    with_bare_urls: usize,
    parser_panics: usize,
    skipped_raw_div_in_notes: usize,
    skipped_nested_notes: usize,
    skipped_wiki: usize,
}

fn compare(md: &str, tally: &mut Tally) -> Result<(), String> {
    let Some(reference) = pulldown_html(md) else {
        tally.parser_panics += 1;
        return Ok(());
    };
    // Wikilinks and tags are additions the reference does not have (their rendering is checked
    // in tests/wiki.rs).
    if Document::new(md, OffsetEncoding::Utf8).spans(None).iter().any(|s| matches!(s.kind, SpanKind::Wikilink | SpanKind::Tag)) {
        tally.skipped_wiki += 1;
        return Ok(());
    }
    tally.compared += 1;
    let mine = ours(md);
    let mut mine = strip_heading_ids(&mine);
    // Our footnote list items and refs are compared through split_footnotes_ours (ids kept there).
    let mine_with_ids = ours(md);
    let has_footnotes = md.contains("[^") && (reference.contains("footnote-") || mine_with_ids.contains("footnote"));
    // pulldown's notes are found by their `<div>`: a raw `div` in the text would be mistaken for their end.
    if has_footnotes && md.contains("div") {
        tally.skipped_raw_div_in_notes += 1;
        return Ok(());
    }
    let mut reference = reference;
    if has_footnotes {
        tally.with_footnotes += 1;
        let (theirs_rest, theirs_bodies) = split_footnotes_pulldown(&reference).ok_or("cannot read pulldown's footnotes")?;
        // A note defined inside another note: pulldown renders it inside the outer one, we list
        // it beside it; the splitter above cannot take them apart.
        if theirs_bodies.values().any(|b| b.contains("footnote-definition"))
            || reference.matches("<div class=\"footnote-definition\"").count() != theirs_bodies.len()
        {
            tally.skipped_nested_notes += 1;
            return Ok(());
        }
        let (mine_rest, mine_bodies) = split_footnotes_ours(&mine_with_ids);
        let mine_bodies: BTreeMap<String, String> =
            mine_bodies.into_iter().map(|(k, v)| (k, normalise_tasks(&unlink_bare_urls(&strip_heading_ids(&v), md)))).collect();
        let theirs_bodies: BTreeMap<String, String> = theirs_bodies.into_iter().map(|(k, v)| (k, normalise_tasks(&unlink_bare_urls(&v, md)))).collect();
        // Every note pulldown shows, we show, with the same body (we may drop a note nobody can
        // reach only if pulldown does too).
        for (name, body) in &theirs_bodies {
            match mine_bodies.get(name) {
                Some(b) if b == body => {}
                other => return Err(format!("footnote {name:?}: pulldown {body:?}, ours {other:?}")),
            }
        }
        if mine_bodies.len() != theirs_bodies.len() {
            return Err(format!("footnotes: pulldown {:?}, ours {:?}", theirs_bodies.keys(), mine_bodies.keys()));
        }
        reference = theirs_rest;
        mine = strip_heading_ids(&mine_rest);
    }
    let urls = !autolink::find(md).is_empty();
    if urls {
        tally.with_bare_urls += 1;
    }
    let mine = unlink_bare_urls(&mine, md);
    let reference = unlink_bare_urls(&reference, md);
    let mut mine = normalise_tasks(&mine).replace("<li>\n", "<li>");
    let mut reference = normalise_tasks(&reference).replace("<li>\n", "<li>");
    if has_footnotes {
        // pulldown writes a newline before a note defined in place, which cutting it out cannot
        // always tell from the text's own: these documents are compared without line breaks
        // (every other document is compared exactly).
        mine = mine.replace('\n', "");
        reference = reference.replace('\n', "");
    }
    if mine == reference {
        tally.equal += 1;
        Ok(())
    } else {
        Err(format!("\n  ours      {mine:?}\n  pulldown  {reference:?}"))
    }
}

fn spec_inputs() -> Vec<(String, String)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json");
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    json.as_array().unwrap().iter().map(|e| (format!("spec example {}", e["example"]), e["markdown"].as_str().unwrap().to_owned())).collect()
}

const MORE: &[&str] = &[
    "- [ ] a\n- [x] b\n\n  para\n",
    "One[^b] and two[^a] and again[^b].\n\n[^a]: Alpha *note*.\n[^b]: Beta.\n\nAfter.\n",
    "[^1]: > quoted\n\n[^1]\n",
    "x[^n]\n\n[^n]: has a ref to [^m]\n[^m]: inner\n",
    "[^u]: nobody refers to me\n\ntext\n",
    "| a | b |\n|:-|-:|\n| `x` | **y** |\n",
    "---\ntitle: T\n---\n\n# H\n\nwww.example.com and https://a.b/c.\n",
    "<div>\n*raw*\n</div>\n\n<span>inline</span> *em*\n",
];

const SOUP: &[&str] = &[
    "# ", "## ", "> ", "- ", "* ", "1. ", "- [ ] ", "- [x] ", "```", "```rs\n", "~~~", "---\n", "***", "\n", "\n\n",
    "\r\n", "  \n", "*", "**", "_", "~~", "`", "[", "](", ")", "![", "]", "[^1]", "[^1]: ", "[^2]", "[^2]: ", "|", "| a | b |\n", "|---|---|\n",
    "<div>", "</div>", "<b>", "<http://a.b>", "www.a.b/c", "http://a.b/x_y", "(www.a.b)", "\\", "\\*", "word ", "text", " ", "    ", "\t", "=== ", "===\n", "[r]: /u\n",
    "[r]", "[r][]", "[t][r]", "\u{1F389}", "e\u{301}", "&amp;", "#", ":", "\"t\"", "'", "(", "<", ">", "\\\n", "x\\|y",
];

#[test]
fn the_renderer_equals_pulldowns_writer_but_for_its_additions() {
    let mut inputs = spec_inputs();
    inputs.extend(fixtures());
    inputs.extend(MORE.iter().map(|t| (format!("{t:?}"), (*t).to_owned())));
    let mut seed = 99u64;
    let n: usize = std::env::var("RENDER_DIFF_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(4000);
    for _ in 0..n {
        let len = (lcg(&mut seed) % 30) as usize;
        let t: String = (0..len).map(|_| SOUP[(lcg(&mut seed) as usize) % SOUP.len()]).collect();
        inputs.push((format!("random {t:?}"), t));
    }
    let mut tally = Tally::default();
    let mut failures = Vec::new();
    for (name, md) in &inputs {
        if let Err(e) = compare(md, &mut tally) {
            failures.push(format!("{name}: {e}"));
        }
    }
    println!("{tally:?}");
    assert!(failures.is_empty(), "{} of {} differ:\n{}", failures.len(), inputs.len(), failures.iter().take(15).cloned().collect::<Vec<_>>().join("\n"));
    assert!(tally.with_footnotes > 50 && tally.with_bare_urls > 50, "{tally:?}");
}
