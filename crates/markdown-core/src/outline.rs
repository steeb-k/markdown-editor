//! The text of a heading for an outline: what the renderer reads as the heading's plain text (the same events as
//! the ids' slugs are made from), without rendering the document.

use pulldown_cmark::{Event, Parser, Tag, TagEnd};

use crate::analysis::options;

/// The plain text of the heading written as `source` (its block's source range). `contained`: the heading is
/// inside a quote or a list item, so lines after the first of a setext heading may start with the container's
/// markers, which are not part of it.
pub(crate) fn heading_text(source: &str, contained: bool) -> String {
    let normalized;
    let source = if contained && source.contains(['\n', '\r']) {
        let mut lines = source.split_inclusive(['\n', '\r']);
        let mut out = String::with_capacity(source.len());
        if let Some(first) = lines.next() {
            out.push_str(first);
        }
        for line in lines {
            out.push_str(line.trim_start_matches([' ', '\t', '>']));
        }
        normalized = out;
        normalized.as_str()
    } else {
        source
    };
    // pulldown-cmark panics on some inputs (see `analyze`): a heading that does that is shown as written.
    let parsed = std::panic::catch_unwind(|| {
        let mut text = String::new();
        let mut inside = false;
        for event in Parser::new_ext(source, options()) {
            match event {
                Event::Start(Tag::Heading { .. }) => inside = true,
                Event::End(TagEnd::Heading(_)) => break,
                Event::Text(t) | Event::Code(t) if inside => text.push_str(&t),
                Event::SoftBreak | Event::HardBreak if inside => text.push(' '),
                _ => {}
            }
        }
        text
    });
    match parsed {
        Ok(text) => text.trim().to_owned(),
        Err(_) => source.trim_matches(|c: char| c == '#' || c.is_whitespace()).to_owned(),
    }
}
