//! Syntax highlighting of fenced code for the preview, with `syntect`.
//!
//! Class-based: the output carries scope classes (`<span class="s-keyword s-control">`),
//! never colors, so the preview's stylesheet decides how they look (see `preview_css`). The
//! pure-Rust regex backend (`fancy-regex`) keeps the core free of C code.
//!
//! The bundled syntax set is loaded once, on first use (a static), and costs tens of
//! milliseconds; a shell may call [`warm_up`] from a background thread before the first
//! preview is shown. It is syntect's default set (Sublime's "Packages"): C, C++, C#, CSS, Go,
//! Haskell, HTML, Java, JavaScript, JSON, LaTeX, Lua, Markdown, Objective-C, OCaml, Perl, PHP,
//! Python, R, Ruby, Rust, Scala, SQL, shell, XML, YAML and a few more. There is no TypeScript,
//! TOML, Swift or Kotlin: `ts`, `tsx` and `jsx` borrow JavaScript's rules, every other
//! unknown language is shown as plain, escaped text.

use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use std::collections::HashMap;

use pulldown_cmark_escape::escape_html_body_text;
use syntect::parsing::{BasicScopeStackOp, ParseState, Scope, ScopeStack, SyntaxReference, SyntaxSet};
use syntect::util::LinesWithEndings;

/// The prefix of every class syntect writes, so they cannot collide with the document's own.
pub const CLASS_PREFIX: &str = "s-";

/// Blocks above this size are shown plain: highlighting is for reading, not for log files.
const MAX_HIGHLIGHT_BYTES: usize = 200_000;
/// A block with a line longer than this is shown plain: the regex engine's cost grows with the
/// line (and can backtrack badly on minified code).
const MAX_LINE_BYTES: usize = 1_000;
/// What a line costs, in bytes of the render's highlighting budget, beyond its own length: the
/// per-line work of the parser dominates for ordinary code.
const LINE_COST: usize = 48;

/// Whether `highlight` would try this block (a known language, not too large, no giant line).
pub fn is_highlightable(info: &str, code: &str) -> bool {
    code.len() <= MAX_HIGHLIGHT_BYTES && !code.split('\n').any(|l| l.len() > MAX_LINE_BYTES) && find_syntax(info).is_some()
}

/// The block's share of a render's highlighting budget (see `render::HIGHLIGHT_BUDGET_BYTES`).
pub fn cost(code: &str) -> usize {
    code.len() + LINE_COST * (code.matches('\n').count() + 1)
}

static SYNTAXES: OnceLock<SyntaxSet> = OnceLock::new();

fn syntaxes() -> &'static SyntaxSet {
    SYNTAXES.get_or_init(SyntaxSet::load_defaults_newlines)
}

/// Loads the bundled syntaxes now (idempotent). Cheap to call from a worker thread at start-up.
pub fn warm_up() {
    let _ = syntaxes();
}

/// Names of the languages the highlighter knows, for documentation and tests.
pub fn language_names() -> Vec<String> {
    syntaxes().syntaxes().iter().map(|s| s.name.clone()).collect()
}

fn find_syntax(info: &str) -> Option<&'static SyntaxReference> {
    let ss = syntaxes();
    // "rust,ignore", "python {.numberLines}", "js title=x": the language is the first word.
    let token = info.split(|c: char| c.is_whitespace() || c == ',' || c == '{' || c == '}').find(|t| !t.is_empty())?;
    let token = token.trim_start_matches('.');
    let lower = token.to_ascii_lowercase();
    let alias = match lower.as_str() {
        "ts" | "tsx" | "jsx" | "typescript" | "mjs" | "cjs" => "js",
        "shell" | "zsh" | "console" | "shellscript" => "sh",
        "c++" | "cc" | "hpp" | "cxx" => "cpp",
        "objective-c" | "objc" => "m",
        "yml" => "yaml",
        "golang" => "go",
        "csharp" => "cs",
        other => other,
    };
    let syntax = ss.find_syntax_by_token(alias).or_else(|| ss.find_syntax_by_token(token))?;
    (syntax.name != "Plain Text").then_some(syntax)
}

/// The scopes worth a colour; everything else (`source`, `meta`, `punctuation`, `text`...) inherits
/// from its parent, so its span would only add bytes.
const STYLED: [&str; 10] =
    ["comment", "string", "constant", "keyword", "storage", "entity", "support", "variable", "markup", "invalid"];

/// `s-entity s-name s-function` for `entity.name.function.rust`: at most three atoms (the rest is
/// the language's own suffix), each prefixed. `None` for a scope that is not styled.
fn classes_of(scope: Scope) -> Option<String> {
    let name = scope.build_string();
    let mut atoms = name.split('.');
    let first = atoms.next()?;
    if !STYLED.contains(&first) {
        return None;
    }
    let mut out = String::new();
    for atom in std::iter::once(first).chain(atoms).take(3) {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(CLASS_PREFIX);
        out.extend(atom.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_'));
    }
    Some(out)
}

/// `code` as class-based HTML (`<span class="s-keyword s-control">`), or `None` when the language
/// is unknown, plain text, the block is too large, or the highlighter failed (the caller then
/// writes the escaped text). Only the scopes that get a colour become spans.
pub fn highlight(info: &str, code: &str) -> Option<String> {
    highlight_until(info, code, None)
}

/// [`highlight`], giving up (`None`) once `deadline` has passed: checked between lines, so a
/// render's highlighting stops within a line's work of it. A block answered from the cache
/// costs nothing and is always given.
pub fn highlight_until(info: &str, code: &str, deadline: Option<Instant>) -> Option<String> {
    if code.len() > MAX_HIGHLIGHT_BYTES || code.split('\n').any(|l| l.len() > MAX_LINE_BYTES) {
        return None;
    }
    let syntax = find_syntax(info)?;
    // The preview renders the whole document after every edit; the blocks it did not change are
    // answered from here.
    let key = (syntax.name.clone(), code.to_owned());
    if let Some(hit) = cache().lock().unwrap_or_else(|e| e.into_inner()).entries.get(&key) {
        return Some(hit.clone());
    }
    let html = highlight_uncached(syntax, code, deadline)?;
    let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
    // An entry's size, the map's own overhead per entry included (tiny blocks are not free).
    let size = html.len() + code.len() + key.0.len() + ENTRY_OVERHEAD;
    if c.bytes + size > CACHE_BYTES {
        c.entries.clear();
        c.bytes = 0;
    }
    c.bytes += size;
    c.entries.insert(key, html.clone());
    Some(html)
}

/// Forgets every cached block (tests and benchmarks).
pub fn clear_cache() {
    let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
    c.entries.clear();
    c.bytes = 0;
}

/// Highlighted blocks kept between renders, keyed by language and code; emptied when it outgrows this.
const CACHE_BYTES: usize = 8 << 20;
const ENTRY_OVERHEAD: usize = 128;

/// How much the cache holds, in its own accounting (tests: it stays bounded).
pub fn cache_bytes() -> usize {
    cache().lock().unwrap_or_else(|e| e.into_inner()).bytes
}

#[derive(Default)]
struct Cache {
    entries: HashMap<(String, String), String>,
    bytes: usize,
}

fn cache() -> &'static Mutex<Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default)
}

fn highlight_uncached(syntax: &SyntaxReference, code: &str, deadline: Option<Instant>) -> Option<String> {
    let ss = syntaxes();
    let mut state = ParseState::new(syntax);
    let mut stack = ScopeStack::new();
    let mut html = String::with_capacity(code.len() * 3 / 2);
    // For each scope on the stack: whether it opened a span.
    let mut open: Vec<bool> = Vec::new();
    let mut classes: HashMap<Scope, Option<String>> = HashMap::new();
    for line in LinesWithEndings::from(code) {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return None;
        }
        let ops = state.parse_line(line, ss).ok()?;
        let mut at = 0;
        for (i, op) in &ops {
            if *i > at {
                let _ = escape_html_body_text(&mut html, &line[at..*i]);
                at = *i;
            }
            stack
                .apply_with_hook(op, |basic, _| match basic {
                    BasicScopeStackOp::Push(scope) => {
                        let class = classes.entry(scope).or_insert_with(|| classes_of(scope));
                        match class {
                            Some(c) => {
                                html.push_str("<span class=\"");
                                html.push_str(c);
                                html.push_str("\">");
                                open.push(true);
                            }
                            None => open.push(false),
                        }
                    }
                    BasicScopeStackOp::Pop => {
                        if open.pop() == Some(true) {
                            html.push_str("</span>");
                        }
                    }
                })
                .ok()?;
        }
        let _ = escape_html_body_text(&mut html, &line[at..]);
    }
    while let Some(opened) = open.pop() {
        if opened {
            html.push_str("</span>");
        }
    }
    Some(html)
}
