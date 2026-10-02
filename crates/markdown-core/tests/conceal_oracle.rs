//! Live mode concealment judged from outside:
//!
//! * **Rendering oracle**: with every owner untouched, the source that stays visible (minus
//!   hidden ranges and collapsed lines, decorations replaced by a placeholder) has the same
//!   non-blank characters as pulldown-cmark's rendering of the document. A difference means
//!   letters were hidden or markup was left showing.
//! * **Touch rule**: a caret anywhere in a markup span's owner (edges included) reveals it, a
//!   caret one unit outside does not (unless another owner of the same span covers it).
//! * **Invariants** in all three encodings, windowed queries included.
mod common;
use common::*;
use markdown_core::*;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
}

fn spec_examples() -> Vec<(u64, String)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json");
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    json.as_array()
        .unwrap()
        .iter()
        .map(|e| (e["example"].as_u64().unwrap(), e["markdown"].as_str().unwrap().to_owned()))
        .collect()
}

const IMAGE: char = '▣';
const RULE: char = '▬';
const OPEN: char = '☐';
const DONE: char = '☑';

fn placeholder(k: DecorationKind) -> Option<char> {
    match k {
        DecorationKind::Image { .. } => Some(IMAGE),
        DecorationKind::Rule => Some(RULE),
        DecorationKind::Checkbox { checked } => Some(if checked { DONE } else { OPEN }),
        // A bullet is drawn over its marker: the marker is not text in the rendering.
        DecorationKind::Bullet => Some(' '),
        DecorationKind::QuoteBar { .. } => None,
    }
}

/// What pulldown-cmark renders as text, with the documented exceptions folded in: tables,
/// footnote labels and references and raw HTML are kept as source (Live mode never hides
/// them), standalone images and rules and task markers become the decoration placeholders.
fn rendered(text: &str, doc: &Document) -> Option<String> {
    let events = std::panic::catch_unwind(|| Parser::new_ext(text, options()).into_offset_iter().collect::<Vec<_>>()).ok()?;
    // By start: pulldown-cmark's range for a reference image can differ from the element's.
    // A standalone image written over several lines stays source (documented fallback).
    let standalone: Vec<usize> = doc
        .images()
        .iter()
        .filter(|i| i.standalone && !text[i.range.start as usize..i.range.end as usize].contains(['\n', '\r']))
        .map(|i| i.range.start as usize)
        .collect();
    let mut out = String::new();
    let mut skip_until: Option<(usize, TagEnd)> = None; // (depth, end tag)
    let mut depth = 0usize;
    let mut ordered: Vec<bool> = Vec::new();
    // pulldown-cmark quirk: after a link reference definition and a line of blanks, a lone
    // `-` or `---` becomes an *empty* setext heading (CommonMark: a list item or a rule). The
    // underline of an empty heading is left visible; such documents are not judged.
    if events.windows(2).any(|w| matches!((&w[0].0, &w[1].0), (Event::Start(Tag::Heading { .. }), Event::End(TagEnd::Heading(_))))) {
        return None;
    }
    // pulldown-cmark quirk (`oracle.rs::known_pulldown_quirks`): a task marker right before a
    // table in a list item is not rendered at all.
    let tasks = events.iter().filter(|(e, _)| matches!(e, Event::TaskListMarker(_))).count();
    if doc.spans(None).iter().filter(|s| matches!(s.kind, SpanKind::TaskMarker { .. })).count() != tasks {
        return None;
    }
    for (ev, r) in events {
        match &ev {
            Event::Start(_) => depth += 1,
            Event::End(_) => depth -= 1,
            _ => {}
        }
        if let Some((d, end)) = &skip_until {
            if let Event::End(e) = &ev
                && *e == *end
                && depth + 1 == *d
            {
                skip_until = None;
            }
            continue;
        }
        let src = &text[r.clone()];
        match ev {
            Event::Text(t) => {
                // An entity or numeric reference stays as written in the source.
                if src.starts_with('&') && src != &*t { out.push_str(src) } else { out.push_str(&t) }
            }
            Event::Code(t) | Event::Html(t) | Event::InlineHtml(t) => out.push_str(&t),
            Event::FootnoteReference(_) => out.push_str(src),
            Event::Rule => out.push(RULE),
            // Documented fallback: in an ordered item the marker stays as written.
            Event::TaskListMarker(_) if ordered.last() == Some(&true) => out.push_str(src),
            Event::TaskListMarker(c) => out.push(if c { DONE } else { OPEN }),
            Event::Start(Tag::List(first)) => ordered.push(first.is_some()),
            Event::End(TagEnd::List(_)) => {
                ordered.pop();
            }
            Event::Start(Tag::Image { .. }) if standalone.contains(&r.start) => {
                out.push(IMAGE);
                skip_until = Some((depth, TagEnd::Image));
            }
            Event::Start(Tag::Table(_)) => {
                out.push_str(src);
                skip_until = Some((depth, TagEnd::Table));
            }
            Event::Start(Tag::FootnoteDefinition(_)) => {
                if let Some(i) = src.find("]:") {
                    out.push_str(&src[..i + 2]);
                }
            }
            _ => {}
        }
    }
    Some(out)
}

/// Concealment with every owner untouched: the union over carets at every boundary (each
/// piece of markup is hidden under some caret unless its owner spans the whole document).
fn untouched(doc: &Document) -> Concealment {
    let enc = doc.encoding();
    let bs = boundaries(doc.text(), enc);
    let mut hidden = Vec::new();
    let mut collapsed = Vec::new();
    let mut decorations = Vec::new();
    for &p in &bs {
        let c = doc.concealment(TextRange::new(p, p), None);
        hidden.extend(c.hidden);
        collapsed.extend(c.collapsed);
        decorations.extend(c.decorations);
    }
    hidden.sort();
    hidden.dedup();
    collapsed.sort();
    collapsed.dedup();
    decorations.sort_by_key(|d| (d.range.start, std::cmp::Reverse(d.range.end), format!("{:?}", d.kind)));
    decorations.dedup();
    Concealment { hidden, collapsed, decorations }
}

/// The visible source under `c` (UTF-8 document).
fn visible(text: &str, doc: &Document, c: &Concealment) -> String {
    let n = text.len();
    let mut gone = vec![false; n];
    let mut place: Vec<Option<char>> = vec![None; n];
    for r in c.hidden.iter().chain(&c.collapsed) {
        for g in &mut gone[r.start as usize..r.end as usize] {
            *g = true;
        }
    }
    for d in &c.decorations {
        if let Some(p) = placeholder(d.kind) {
            for g in &mut gone[d.range.start as usize..d.range.end as usize] {
                *g = true;
            }
            place[d.range.start as usize] = Some(p);
        }
    }
    // Exception: ordered list numbers stay visible as written (they are not text in the
    // rendering); link reference definitions are never hidden and not rendered.
    for s in doc.spans(None) {
        if s.kind == (SpanKind::ListMarker { ordered: true }) {
            for g in &mut gone[s.range.start as usize..s.range.end as usize] {
                *g = true;
            }
        }
    }
    // Duplicate definitions are not in pulldown-cmark's map: a definition is also any line
    // holding a destination outside a link or image.
    let spans = doc.spans(None);
    for d in spans.iter().filter(|s| s.kind == SpanKind::LinkDestination) {
        let inside = spans.iter().any(|o| {
            matches!(o.kind, SpanKind::Link | SpanKind::Image) && o.range.start <= d.range.start && d.range.end <= o.range.end
        });
        if !inside {
            let mut ls = text[..d.range.start as usize].rfind('\n').map_or(0, |i| i + 1);
            // A definition inside a footnote definition: the footnote label stays.
            if let Some(k) = text[ls..d.range.start as usize].rfind("[^")
                && let Some(i) = text[ls + k..d.range.start as usize].find("]:")
            {
                ls += k + i + 2;
            }
            let le = text[d.range.end as usize..].find('\n').map_or(n, |i| d.range.end as usize + i);
            for g in &mut gone[ls..le] {
                *g = true;
            }
        }
    }
    if let Ok(defs) = std::panic::catch_unwind(|| {
        let mut it = Parser::new_ext(text, options()).into_offset_iter();
        for _ in it.by_ref() {}
        it.reference_definitions().iter().map(|(_, d)| d.span.clone()).collect::<Vec<_>>()
    }) {
        for r in defs {
            for g in &mut gone[r.start..r.end.min(n)] {
                *g = true;
            }
        }
    }
    let mut out = String::new();
    for (i, ch) in text.char_indices() {
        if let Some(p) = place[i] {
            out.push(p);
        }
        if !gone[i] {
            out.push(ch);
        }
    }
    out
}

fn squeeze(s: &str) -> String {
    s.chars().filter(|c| !c.is_whitespace()).collect()
}

/// `None` when the visible text matches the rendering; else a description.
///
/// "Every owner untouched": the document gets a plain paragraph in front of it and the caret
/// goes there (a paragraph and a blank line change nothing about how the rest parses, except
/// front matter, which must start the file: those documents use the union over all carets).
fn judge(text: &str) -> Option<String> {
    let front = text.starts_with("---");
    let text = if front { text.to_owned() } else { format!("zz\n\n{text}") };
    let doc = Document::new(&text, OffsetEncoding::Utf8);
    let r = rendered(&text, &doc)?;
    let c = if front { untouched(&doc) } else { doc.concealment(TextRange::new(0, 0), None) };
    let v = visible(&text, &doc, &c);
    let (sv, sr) = (squeeze(&v), squeeze(&r));
    if sv == sr {
        return None;
    }
    // pulldown-cmark quirk: a tab-indented `>` line inside a quoted code or HTML block is
    // sometimes taken as a quote marker without being reported; the core leaves it visible
    // (see `quote_markup`).
    if text.contains("\t>") && sv.replace('>', "") == sr.replace('>', "") {
        return None;
    }
    // A duplicate link reference definition whose destination is on the next line is not
    // recognised by the core either: it shows as text (never hidden), and is not rendered.
    if text.contains("]:\n") && sv.len() > sr.len() {
        return None;
    }
    // The task-marker-before-a-table quirk when the core sees no task marker either.
    if text.contains("[x] |") || text.contains("[ ] |") {
        return None;
    }
    Some(format!(
        "visible  {v:?}\nrendered {r:?}\nhidden {:?}",
        c.hidden.iter().map(|h| &text[h.start as usize..h.end as usize]).collect::<Vec<_>>()
    ))
}

/// Inputs that failed the rendering oracle once.
const REGRESSIONS: &[&str] = &[
    // An indented "closing fence" is content: the block is unclosed.
    "```\naaa\n    ```\n",
    "- ```\n  a\n      ```\n",
    // A code span over two lines of a quote: the second `>` is the quote's marker.
    "\"t\"\r\n> === ``__\\*x\\|y\\*[r]: /u\n>***`` `  * ",
    "> a `b\n> c` d\n",
    "> a <span\n> title=x> d\n",
    // ... but a `>` four blanks in on a lazy line of a code span is content.
    "> - [^1]: *x ```rs\n    a\n    >b\n> c ```\n",
    // A quote in a list item: its `>` lines are four columns in, and still markers.
    "- > ```rs\n    >\n---\n",
    "- > a\n    > b\n",
];

#[test]
fn rendering_oracle_spec_fixtures_and_regressions() {
    let mut fails = Vec::new();
    for (ex, md) in spec_examples() {
        if let Some(e) = judge(&md) {
            fails.push(format!("example {ex}: {md:?}\n{e}"));
        }
    }
    for (name, md) in fixtures() {
        if let Some(e) = judge(&md) {
            fails.push(format!("fixture {name}\n{e}"));
        }
    }
    for md in REGRESSIONS {
        if let Some(e) = judge(md) {
            fails.push(format!("regression {md:?}\n{e}"));
        }
    }
    assert!(fails.is_empty(), "{} mismatches:\n{}", fails.len(), fails.join("\n"));
}

const TOKENS: &[&str] = &[
    "# ", "## ", "> ", "- ", "* ", "1. ", "2) ", "- [ ] ", "- [x] ", "```", "```rs\n", "~~~", "---\n", "***", "\n", "\n\n",
    "\r\n", "  \n", "*", "**", "_", "__", "~~", "~", "`", "``", "[", "](", ")", "![", "]", "[^1]", "[^1]: ", "|", "| a | b |\n",
    "|---|---|\n", "<div>", "</div>", "<b>", "<http://a.b>", "<me@a.b>", "www.a.b/c", "http://a.b/x_y ", "\\", "\\*", "word ",
    "text", " ", "  ", "    ", "\t", "=== ", "===\n", "--\n", "[r]: /u\n", "[r]", "[r][]", "[t][r]", "\u{1F389}", "\u{65E5}\u{672C}",
    "e\u{301}", "&amp;", "&#42;", "#", ":", "\"t\"", "'", "(", "<", ">", "\\\n", "x\\|y", "![a](p.png)", "![a](p.png)\n\n",
    "[a](u)", "[![i](x.png)](u)", "+++\n", "a\n", "b ", "\n- ", "\n> ", "\n  - ", "\n   ", "\n1. ", "\n> - ", "\n- > ",
    "**a**", "*a*", "_a_", "[*a*](u)", "[**a** b](u \"t\")", "~~a~~", "`a`", "\n# ", "\n## a\n", "\n---\n", "\n***\n",
    "\n```\n", "\n  ```\n", "\n> ```\n", "[r]: <u v>\n", "<b>x</b>", "\\\\", "\\_", "a_b_c", "**a*b*c**", "***a***",
    "1. [ ] ", "\n2. [x] ", "\n- [ ]", "\n> - [x] ",
];

fn lcg(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    *seed >> 33
}

fn random_doc(seed: &mut u64) -> String {
    let len = (lcg(seed) % 40) as usize;
    (0..len).map(|_| TOKENS[(lcg(seed) as usize) % TOKENS.len()]).collect()
}

/// `CONCEAL_ORACLE_CASES=1000000 cargo test --profile fuzz -p markdown-core --test conceal_oracle`
#[test]
fn rendering_oracle_random_documents() {
    let n: usize = std::env::var("CONCEAL_ORACLE_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(20000);
    let mut seed = 99u64;
    let mut fails = Vec::new();
    for _ in 0..n {
        let text = random_doc(&mut seed);
        if let Some(e) = judge(&text) {
            fails.push(format!("{text:?}\n{e}"));
        }
    }
    assert!(fails.is_empty(), "{} of {n} mismatch:\n{}", fails.len(), fails.iter().take(20).cloned().collect::<Vec<_>>().join("\n"));
}

#[test]
#[ignore]
fn dump_case() {
    let t = std::env::var("CASE").unwrap().replace("\\n", "\n").replace("\\t", "\t");
    for (ev, r) in Parser::new_ext(&t, options()).into_offset_iter() {
        println!("{r:?} {ev:?} {:?}", &t[r.clone()]);
    }
    let doc = Document::new(&t, OffsetEncoding::Utf8);
    for s in doc.spans(None) {
        println!("span {:?} {:?} {:?}", s.range, s.kind, &t[s.range.start as usize..s.range.end as usize]);
    }
    for p in boundaries(&t, OffsetEncoding::Utf8) {
        let c = doc.concealment(TextRange::new(p, p), None);
        println!("caret {p}: {c:?}");
    }
}

// ---------- the touch rule ----------

/// The owner Live mode uses for a markup span: a fence or front matter delimiter belongs to
/// its whole block, a setext underline to its heading through the end of its own line,
/// everything else to the owner the analysis reports.
fn effective_owner(text: &str, spans: &[Span], m: &MarkupSpan) -> (u32, u32) {
    let s = &text[m.range.start as usize..m.range.end as usize];
    let containing = |k: fn(SpanKind) -> bool| {
        spans
            .iter()
            .filter(|o| k(o.kind) && o.range.start <= m.range.start && m.range.end <= o.range.end)
            .min_by_key(|o| o.range.len())
            .map(|o| (o.range.start, o.range.end))
    };
    if s.chars().all(|c| c == '`' || c == '~')
        && s.len() >= 3
        && let Some(o) = containing(|k| k == SpanKind::CodeBlock)
    {
        return o;
    }
    if matches!(s, "---" | "...")
        && let Some(o) = containing(|k| k == SpanKind::FrontMatter)
    {
        return o;
    }
    if m.scope == MarkupScope::Block {
        let le = text[m.range.end as usize..].find(['\n', '\r']).map_or(text.len(), |i| m.range.end as usize + i);
        return (m.owner.start, (m.owner.end as usize).max(le) as u32);
    }
    (m.owner.start, m.owner.end)
}

/// Markup that is never concealed by design: anything in a table, footnote labels and
/// references, link reference definitions.
fn pinned(text: &str, spans: &[Span], m: &MarkupSpan) -> bool {
    if m.in_table {
        return true;
    }
    let inside = |k: SpanKind| spans.iter().any(|o| o.kind == k && o.range.start <= m.range.start && m.range.end <= o.range.end);
    if inside(SpanKind::FootnoteReference) {
        return true;
    }
    // The brackets of a link reference definition's label and of a footnote definition's
    // label: bracket markup outside any link or image.
    let s = &text[m.range.start as usize..m.range.end as usize];
    matches!(s, "[" | "]" | "]:" | "[^")
        && !spans.iter().any(|o| matches!(o.kind, SpanKind::Link | SpanKind::Image) && o.range.start <= m.range.start && m.range.end <= o.range.end)
}

fn covered(hidden: &[TextRange], r: TextRange) -> bool {
    hidden.iter().any(|h| h.start <= r.start && r.end <= h.end)
}

/// For every markup span and every caret: hidden exactly when the caret does not touch the
/// effective owner (edges included). `None` when the rule holds.
fn touch_rule(text: &str) -> Option<String> {
    let doc = Document::new(text, OffsetEncoding::Utf8);
    let spans = doc.spans(None);
    let markup = doc.markup_spans(None);
    let bs = boundaries(text, OffsetEncoding::Utf8);
    let per_caret: Vec<Vec<TextRange>> = bs.iter().map(|&p| doc.concealment(TextRange::new(p, p), None).hidden).collect();
    for m in &markup {
        let is_pinned = pinned(text, &spans, m);
        let (os, oe) = effective_owner(text, &spans, m);
        for (i, &p) in bs.iter().enumerate() {
            let hidden = covered(&per_caret[i], m.range);
            let expect = !(is_pinned || (os <= p && p <= oe));
            if hidden != expect {
                return Some(format!(
                    "markup {:?} {:?} owner {:?} (scope {:?}, effective {os}..{oe}, pinned {is_pinned}) caret {p}: hidden {hidden}, expected {expect}",
                    m.range,
                    &text[m.range.start as usize..m.range.end as usize],
                    m.owner,
                    m.scope,
                ));
            }
        }
        // A selection reveals what it overlaps, and only that.
        for (a, b) in [(os.saturating_sub(1), os), (oe, oe + 1), (os, oe), (os.saturating_sub(2), os + 1), (oe + 1, oe + 2), (os.saturating_sub(2), os.saturating_sub(1)), (os.saturating_sub(1), oe + 1)] {
            let (a, b) = (a.min(text.len() as u32), b.min(text.len() as u32));
            if a >= b || !bs.contains(&a) || !bs.contains(&b) {
                continue;
            }
            let hidden = covered(&doc.concealment(TextRange::new(a, b), None).hidden, m.range);
            let nl = |i: u32| matches!(text.as_bytes().get(i as usize), Some(b'\n' | b'\r'));
            let at = |p: u32| os <= p && p <= oe;
            let touched = (a < oe && os < b) || (!nl(a) && at(a)) || (!(b > 0 && nl(b - 1)) && at(b));
            let expect = !is_pinned && !touched;
            if hidden != expect {
                return Some(format!(
                    "markup {:?} {:?} effective owner {os}..{oe}: selection {a}..{b} hidden {hidden}, expected {expect}",
                    m.range,
                    &text[m.range.start as usize..m.range.end as usize]
                ));
            }
        }
    }
    None
}

#[test]
fn touch_rule_spec_examples_fixtures_and_regressions() {
    let mut fails = Vec::new();
    for (ex, md) in spec_examples() {
        if let Some(e) = touch_rule(&md) {
            fails.push(format!("example {ex}: {md:?}\n  {e}"));
        }
    }
    for (name, md) in fixtures() {
        if let Some(e) = touch_rule(&md) {
            fails.push(format!("fixture {name}\n  {e}"));
        }
    }
    for md in REGRESSIONS {
        if let Some(e) = touch_rule(md) {
            fails.push(format!("regression {md:?}\n  {e}"));
        }
    }
    assert!(fails.is_empty(), "{} failures:\n{}", fails.len(), fails.join("\n"));
}

#[test]
fn touch_rule_random_documents() {
    let n: usize = std::env::var("CONCEAL_ORACLE_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(3000);
    let mut seed = 5u64;
    let mut fails = Vec::new();
    for _ in 0..n {
        let text = random_doc(&mut seed);
        if std::panic::catch_unwind(|| Parser::new_ext(&text, options()).count()).is_err() {
            continue;
        }
        if let Some(e) = touch_rule(&text) {
            fails.push(format!("{text:?}\n  {e}"));
        }
    }
    assert!(fails.is_empty(), "{} of {n} fail:\n{}", fails.len(), fails.iter().take(20).cloned().collect::<Vec<_>>().join("\n"));
}

// ---------- invariants, all encodings ----------

const ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

fn intersects(a: TextRange, w: TextRange) -> bool {
    if w.start == w.end { a.start <= w.start && w.start < a.end } else { a.start < w.end && w.start < a.end }
}

/// What the existing contract test (`conceal.rs`) does not cover: decorations against each
/// other and against `hidden`, and windowed queries against the whole one for every field.
fn invariants(doc: &Document, sel: TextRange, win: TextRange) -> Result<(), String> {
    let text = doc.text();
    let enc = doc.encoding();
    let full = doc.concealment(sel, None);
    // Non-bar decorations never overlap one another; a bar is a whole quote and may hold any.
    let solid: Vec<&Decoration> = full.decorations.iter().filter(|d| !matches!(d.kind, DecorationKind::QuoteBar { .. })).collect();
    for w in solid.windows(2) {
        if w[1].range.start < w[0].range.end {
            return Err(format!("decorations overlap: {:?} {:?}", w[0], w[1]));
        }
    }
    for d in &full.decorations {
        let is_hidden = covered(&full.hidden, d.range);
        let any_hidden = full.hidden.iter().any(|h| h.start < d.range.end && d.range.start < h.end);
        match d.kind {
            // Drawn over a marker that keeps its place.
            DecorationKind::Bullet => {
                if any_hidden {
                    return Err(format!("bullet marker hidden: {d:?}"));
                }
            }
            DecorationKind::Checkbox { .. } | DecorationKind::Rule | DecorationKind::Image { .. } => {
                if !is_hidden {
                    return Err(format!("{d:?} stands for source that is not hidden"));
                }
            }
            DecorationKind::QuoteBar { .. } => {
                let s = slice_units(text, enc, d.range);
                if !s.starts_with('>') {
                    return Err(format!("quote bar {d:?} does not start at a `>`: {s:?}"));
                }
            }
        }
    }
    let part = doc.concealment(sel, Some(win));
    let collapsed: Vec<TextRange> = full.collapsed.iter().copied().filter(|r| intersects(*r, win)).collect();
    if part.collapsed != collapsed {
        return Err(format!("window {win:?}: collapsed {:?}, whole document says {collapsed:?}", part.collapsed));
    }
    let decorations: Vec<Decoration> = full.decorations.iter().copied().filter(|d| intersects(d.range, win)).collect();
    if part.decorations != decorations {
        return Err(format!("window {win:?}: decorations {:?}, whole document says {decorations:?}", part.decorations));
    }
    // A selection over the whole document reveals everything but what is never concealed:
    // the hidden task prefixes and, nothing else.
    Ok(())
}

#[test]
fn invariants_in_every_encoding() {
    let n: usize = std::env::var("CONCEAL_ORACLE_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(4000);
    let mut seed = 11u64;
    let mut inputs: Vec<String> = spec_examples().into_iter().map(|(_, t)| t).collect();
    inputs.extend(fixtures().into_iter().map(|(_, t)| t));
    inputs.extend(REGRESSIONS.iter().map(|s| s.to_string()));
    inputs.push(String::new());
    for _ in 0..n {
        inputs.push(random_doc(&mut seed));
    }
    for text in &inputs {
        for enc in ENCODINGS {
            let doc = Document::new(text, enc);
            let bs = boundaries(text, enc);
            let pick = |seed: &mut u64| bs[(lcg(seed) as usize) % bs.len()];
            for _ in 0..4 {
                let (a, b) = (pick(&mut seed), pick(&mut seed));
                let (x, y) = (pick(&mut seed), pick(&mut seed));
                let sel = if lcg(&mut seed).is_multiple_of(2) { TextRange::new(a, a) } else { TextRange::new(a, b) };
                let win = TextRange::new(x.min(y), x.max(y));
                if let Err(e) = invariants(&doc, sel, win) {
                    panic!("{enc:?} {text:?} sel {sel:?}: {e}");
                }
            }
            // The whole document selected: nothing is hidden but task prefixes.
            let all = doc.concealment(TextRange::new(0, doc.len()), None);
            let tasks: Vec<TextRange> = all.decorations.iter().filter(|d| matches!(d.kind, DecorationKind::Checkbox { .. })).map(|d| d.range).collect();
            for h in &all.hidden {
                if !tasks.iter().any(|t| h.start <= t.start && t.end <= h.end) {
                    panic!("{enc:?} {text:?}: whole-document selection still hides {:?}", slice_units(text, enc, *h));
                }
            }
            if !all.collapsed.is_empty() {
                panic!("{enc:?} {text:?}: whole-document selection collapses {:?}", all.collapsed);
            }
        }
    }
}

#[test]
#[ignore]
fn probe() {
    let cases = std::env::var("PROBE").unwrap();
    for c in cases.split("|||") {
        let c = c.replace("\\n", "\n").replace("\\t", "\t").replace("\\r", "\r");
        let (mut text, mut caret) = (String::new(), 0u32);
        for ch in c.chars() {
            if ch == '¦' { caret = text.len() as u32 } else { text.push(ch) }
        }
        let doc = Document::new(&text, OffsetEncoding::Utf8);
        let k = doc.concealment(TextRange::new(caret, caret), None);
        let h: Vec<&str> = k.hidden.iter().map(|r| &text[r.start as usize..r.end as usize]).collect();
        let col: Vec<&str> = k.collapsed.iter().map(|r| &text[r.start as usize..r.end as usize]).collect();
        let d: Vec<(String, DecorationKind)> = k.decorations.iter().map(|r| (text[r.range.start as usize..r.range.end as usize].to_owned(), r.kind)).collect();
        println!("{c:?}\n   hidden {h:?}\n   collapsed {col:?}\n   decos {d:?}");
    }
}

/// Documents around the offset table's 256-byte checkpoints ending in multi-byte characters
/// (an M1 panic was found there by the shell's stress test).
#[test]
fn invariants_around_offset_checkpoints() {
    for tail in ["\u{1F389}", "\u{65E5}\u{672C}", "e\u{301}", "\u{1F389}**"] {
        for n in 230..540 {
            let body = "x **b** [l](u) `c`\n> q\n".repeat(30);
            let mut text: String = body.chars().take(n).collect();
            text.push_str(tail);
            for enc in ENCODINGS {
                let doc = Document::new(&text, enc);
                let len = doc.len();
                for sel in [TextRange::new(len, len), TextRange::new(0, 0), TextRange::new(0, len)] {
                    if let Err(e) = invariants(&doc, sel, TextRange::new(len / 3, len)) {
                        panic!("{enc:?} n={n} {tail:?}: {e}");
                    }
                }
            }
        }
    }
}
