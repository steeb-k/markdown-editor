//! Bare-URL autolinks: the GFM spec's extended-autolink examples, and how the analysis
//! applies them (spans, prose, where they must not apply).
mod common;
use common::*;
use markdown_core::autolink::{find, Autolink};
use markdown_core::*;

fn urls(text: &str) -> Vec<String> {
    find(text).into_iter().map(|a| text[a.start..a.end].to_owned()).collect()
}

fn link_texts(text: &str) -> Vec<String> {
    texts(text, "Link")
}

#[test]
fn gfm_spec_www_examples() {
    assert_eq!(urls("www.commonmark.org"), ["www.commonmark.org"]);
    assert_eq!(urls("Visit www.commonmark.org/help for more information."), ["www.commonmark.org/help"]);
    // Trailing punctuation is not part of the link.
    assert_eq!(urls("Visit www.commonmark.org.\n\nVisit www.commonmark.org/a.b."), ["www.commonmark.org", "www.commonmark.org/a.b"]);
    // Unbalanced closing parentheses are dropped, balanced ones kept.
    assert_eq!(urls("www.google.com/search?q=Markup+(business)"), ["www.google.com/search?q=Markup+(business)"]);
    assert_eq!(urls("www.google.com/search?q=Markup+(business)))"), ["www.google.com/search?q=Markup+(business)"]);
    assert_eq!(urls("(www.google.com/search?q=Markup+(business))"), ["www.google.com/search?q=Markup+(business)"]);
    assert_eq!(urls("(www.google.com/search?q=Markup+(business)"), ["www.google.com/search?q=Markup+(business)"]);
    assert_eq!(urls("www.google.com/search?q=(business))+ok"), ["www.google.com/search?q=(business))+ok"]);
    // An entity-like ending is excluded.
    assert_eq!(urls("www.google.com/search?q=commonmark&hl=en"), ["www.google.com/search?q=commonmark&hl=en"]);
    assert_eq!(urls("www.google.com/search?q=commonmark&hl;"), ["www.google.com/search?q=commonmark"]);
    // `<` ends the link.
    assert_eq!(urls("www.commonmark.org/he<lp"), ["www.commonmark.org/he"]);
}

#[test]
fn gfm_spec_url_examples() {
    assert_eq!(urls("http://commonmark.org"), ["http://commonmark.org"]);
    assert_eq!(urls("Visit https://encrypted.google.com/search?q=Markup+(business)"), ["https://encrypted.google.com/search?q=Markup+(business)"]);
    assert_eq!(urls("HTTP://EXAMPLE.COM/x"), ["HTTP://EXAMPLE.COM/x"]);
}

#[test]
fn destinations() {
    let a: Vec<Autolink> = find("a www.x.org b http://y.org");
    assert_eq!(a[0].destination, "http://www.x.org");
    assert_eq!(a[1].destination, "http://y.org");
}

#[test]
fn what_is_not_a_link() {
    for t in [
        "xwww.a.com",
        "ahttp://a.com",
        "www.a_b.com",
        "www.a.b_c",
        "www.",
        "www",
        "see:www.a.com",
        "\"www.a.com\"",
        "www..com",
        "http://",
        "https:/a.com",
        "ftp://a.com",
    ] {
        assert_eq!(urls(t), Vec::<String>::new(), "{t:?}");
    }
}

/// After a scheme the host needs no period, as in cmark-gfm (GitHub links these); quotes are
/// trailing punctuation there too.
#[test]
fn cmark_gfm_compatibility() {
    assert_eq!(urls("open http://localhost:3000/x now"), ["http://localhost:3000/x"]);
    assert_eq!(urls("https://intranet"), ["https://intranet"]);
    assert_eq!(urls("x https://a.b/c\". y www.a.com'"), ["https://a.b/c", "www.a.com"]);
    assert_eq!(urls("www.a.com/it's"), ["www.a.com/it's"]);
    assert_eq!(urls("http://a_b"), Vec::<String>::new());
}

#[test]
fn predecessors_and_trailing_punctuation() {
    assert_eq!(urls("(www.a.com)"), ["www.a.com"]);
    assert_eq!(urls("*www.a.com*"), ["www.a.com"]);
    assert_eq!(urls("_www.a.com_"), ["www.a.com"]);
    assert_eq!(urls("~www.a.com~"), ["www.a.com"]);
    assert_eq!(urls("a\twww.a.com,"), ["www.a.com"]);
    assert_eq!(urls("www.a.com?!"), ["www.a.com"]);
    assert_eq!(urls("www.a.com/p:"), ["www.a.com/p"]);
    assert_eq!(urls("www.a-b.com/\u{e9}\u{1F389}"), ["www.a-b.com/\u{e9}\u{1F389}"]);
    assert_eq!(urls("www.a.com www.b.com"), ["www.a.com", "www.b.com"]);
}

#[test]
fn bare_urls_become_link_spans_without_markup() {
    let text = "go to https://example.com/a_b_c now";
    assert_eq!(link_texts(text), ["https://example.com/a_b_c"]);
    assert!(markup_texts(text).is_empty());
    let doc = Document::new(text, OffsetEncoding::Utf16);
    check_everything(&doc).unwrap();
    // Not prose.
    let prose: Vec<String> = doc.prose_ranges(None).iter().map(|r| slice_units(text, OffsetEncoding::Utf16, *r)).collect();
    assert_eq!(prose, ["go to ", " now"]);
}

#[test]
fn urls_inside_other_inline_elements() {
    assert_eq!(link_texts("**www.a.com**"), ["www.a.com"]);
    assert_eq!(link_texts("*www.a.com/x*"), ["www.a.com/x"]);
    assert_eq!(link_texts("# www.a.com"), ["www.a.com"]);
    assert_eq!(link_texts("> www.a.com"), ["www.a.com"]);
    assert_eq!(link_texts("- www.a.com\n- www.b.com"), ["www.a.com", "www.b.com"]);
    assert_eq!(link_texts("| h |\n|---|\n| www.a.com |"), ["www.a.com"]);
    assert_eq!(link_texts("line one\nwww.a.com two"), ["www.a.com"]);
    // Source-contiguous text events are one run: `_` and `&` inside the URL do not end it.
    assert_eq!(link_texts("http://a.com/x_y&amp;z_w"), ["http://a.com/x_y&amp;z_w"]);
}

#[test]
fn urls_where_they_must_not_apply() {
    for t in [
        "`www.a.com`",
        "``http://a.com``",
        "    www.a.com",
        "```\nwww.a.com\n```",
        "[www.a.com](http://b.com)",
        "[x](http://b.com) and [www.c.com][r]\n\n[r]: /u",
        "![www.a.com](x.png)",
        "<www.a.com>",
        "<http://a.com>",
        "<b title=\"www.a.com\">",
        "<div>\nwww.a.com\n</div>",
        "---\nurl: http://a.com\n---\n",
        "[ref]: http://a.com",
    ] {
        let links: Vec<String> = link_texts(t);
        // Only genuine links (inline, reference, `<...>`) may remain: never a bare-URL span.
        let doc = Document::new(t, OffsetEncoding::Utf8);
        for s in doc.spans(None).iter().filter(|s| s.kind == SpanKind::Link) {
            let inner: Vec<_> = doc.markup_spans(None).into_iter().filter(|m| m.owner == s.range).collect();
            assert!(!inner.is_empty(), "bare-URL link span in {t:?}: {links:?}");
        }
        check_everything(&doc).unwrap();
    }
}

#[test]
fn offsets_agree_across_encodings() {
    let text = "\u{1F389} caf\u{e9} www.a.com/\u{65E5}\u{672C} \u{1F389}";
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let doc = Document::new(text, enc);
        check_everything(&doc).unwrap();
        let links: Vec<String> =
            doc.spans(None).iter().filter(|s| s.kind == SpanKind::Link).map(|s| slice_units(text, enc, s.range)).collect();
        assert_eq!(links, ["www.a.com/\u{65E5}\u{672C}"], "{enc:?}");
    }
}

#[test]
fn editing_a_url_updates_the_link() {
    let mut doc = Document::new("see www.a.com", OffsetEncoding::Utf8);
    assert_eq!(doc.spans(None).len(), 1);
    doc.replace(TextRange::new(4, 4), "x").unwrap();
    assert_eq!(doc.spans(None).len(), 0);
    doc.set_text("see www.a.com");
    doc.replace(TextRange::new(13, 13), "/path").unwrap();
    assert_eq!(doc.spans(None)[0].range, TextRange::new(4, 18));
}
