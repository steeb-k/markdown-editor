//! Syntax highlighting of fenced code, with `syntect`: class-based HTML for the preview and runs of colour
//! roles for the editor ([`roles_until`], used by `Document::code_highlights`), both from one cache.
//!
//! Class-based: the output carries scope classes (`<span class="s-keyword s-control">`),
//! never colors, so the preview's stylesheet decides how they look (see `preview_css`). The
//! pure-Rust regex backend (`fancy-regex`) keeps the core free of C code.
//!
//! The bundled syntax set is loaded once, on first use (a static), and costs a few milliseconds;
//! each language's rules are compiled the first time it is used (10 to 50 ms, TypeScript about 100),
//! so a shell may call [`warm_up`] from a background thread before the first preview is shown. It
//! is `two-face`'s set (`bat`'s curated syntaxes, which include Sublime's default packages): 213
//! syntaxes, among them C, C++, C#, CSS, Dockerfile, Go, Haskell, HTML, Java, JavaScript, JSON,
//! Kotlin, LaTeX, Lua, Markdown, Objective-C, PHP, Python, Ruby, Rust, SCSS, SQL, shell, Swift,
//! TOML, TypeScript (and TSX), XML, YAML and Zig. `jsx`, `mjs` and `cjs` borrow JavaScript's rules;
//! every other unknown language is shown as plain, escaped text. Their licenses are listed in
//! `Acknowledgements.md` (scripts/gen-acknowledgements.py).

use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use std::collections::HashMap;

use pulldown_cmark_escape::escape_html_body_text;
use syntect::parsing::{BasicScopeStackOp, ParseState, Scope, ScopeStack, SyntaxReference, SyntaxSet};
use syntect::util::LinesWithEndings;

use crate::types::CodeRole;

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
    SYNTAXES.get_or_init(two_face::syntax::extra_newlines)
}

/// Loads the bundled syntaxes now (idempotent). Cheap to call from a worker thread at start-up.
pub fn warm_up() {
    let _ = syntaxes();
}

/// Names of the languages the highlighter knows, for documentation and tests.
pub fn language_names() -> Vec<String> {
    syntaxes().syntaxes().iter().map(|s| s.name.clone()).collect()
}

/// Where the language token is in an info string, as byte offsets: the first word, which ends at a
/// blank, a comma or a brace, and which may start with dots (`{.rust}`, `.rust`). `None` when the
/// string has no word.
pub fn info_token(info: &str) -> Option<(usize, usize)> {
    // "rust,ignore", "python {.numberLines}", "js title=x": the language is the first word.
    let sep = |c: char| c.is_whitespace() || c == ',' || c == '{' || c == '}';
    let start = info.find(|c: char| !sep(c))?;
    let word = &info[start..];
    let end = start + word.find(sep).unwrap_or(word.len());
    let start = start + (end - start - info[start..end].trim_start_matches('.').len());
    (start < end).then_some((start, end))
}

fn find_syntax(info: &str) -> Option<&'static SyntaxReference> {
    let ss = syntaxes();
    let (a, b) = info_token(info)?;
    let token = &info[a..b];
    let lower = token.to_ascii_lowercase();
    let alias = match lower.as_str() {
        "jsx" | "mjs" | "cjs" => "js",
        "jsonc" | "json5" => "json",
        "docker" => "dockerfile",
        "fsharp" => "fs",
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

/// The language's own name (`Rust`) for the first word of `info`, if the highlighter knows it.
pub fn language_name(info: &str) -> Option<String> {
    find_syntax(info).map(|s| s.name.clone())
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
    if !within_limits(code) {
        return None;
    }
    let syntax = find_syntax(info)?;
    // The preview renders the whole document after every edit; the blocks it did not change are
    // answered from here.
    let key = (syntax.name.clone(), code.to_owned());
    if let Some(hit) = lookup(&key, |e| e.html.clone()) {
        return Some(hit);
    }
    let html = highlight_uncached(syntax, code, deadline)?;
    let size = html.len();
    store(key, size, |e| e.html = Some(html.clone()));
    Some(html)
}

fn within_limits(code: &str) -> bool {
    code.len() <= MAX_HIGHLIGHT_BYTES && !code.split('\n').any(|l| l.len() > MAX_LINE_BYTES)
}

/// A highlighted stretch of a block's code: byte offsets into the code, and what it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RoleRun {
    pub start: u32,
    pub end: u32,
    pub role: CodeRole,
}

/// The editor's output for a block: its runs of roles, the same scopes as [`highlight`]'s classes
/// and the same limits, answered from the same cache (so a second query is free, and so is a block
/// the preview already did, if it is asked for the roles too). `None`: unknown language, over the
/// limits, or past `deadline` (the block is then plain, never partly coloured).
pub fn roles_until(info: &str, code: &str, deadline: Option<Instant>) -> Option<Arc<[RoleRun]>> {
    if !within_limits(code) {
        return None;
    }
    let syntax = find_syntax(info)?;
    let key = (syntax.name.clone(), code.to_owned());
    if let Some(hit) = lookup(&key, |e| e.roles.clone()) {
        return Some(hit);
    }
    let runs: Arc<[RoleRun]> = roles_uncached(syntax, code, deadline)?.into();
    let size = runs.len() * std::mem::size_of::<RoleRun>();
    store(key, size, |e| e.roles = Some(runs.clone()));
    Some(runs)
}

/// [`roles_until`] for a block already in the cache; never computes anything.
pub fn roles_cached(info: &str, code: &str) -> Option<Arc<[RoleRun]>> {
    let syntax = find_syntax(info)?;
    lookup(&(syntax.name.clone(), code.to_owned()), |e| e.roles.clone())
}

fn lookup<T>(key: &(String, String), f: impl FnOnce(&Entry) -> Option<T>) -> Option<T> {
    let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
    c.clock += 1;
    let now = c.clock;
    let entry = c.entries.get_mut(key)?;
    entry.used = now;
    f(entry)
}

/// Adds an output of `added` bytes to the block's entry (made when it is the first).
fn store(key: (String, String), added: usize, set: impl FnOnce(&mut Entry)) {
    let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
    // An entry's size, the map's own overhead per entry included (tiny blocks are not free).
    let size = added + key.0.len() + key.1.len() + ENTRY_OVERHEAD;
    if c.bytes + size > CACHE_BYTES {
        c.evict();
    }
    c.clock += 1;
    let now = c.clock;
    match c.entries.get_mut(&key) {
        Some(e) => {
            set(e);
            e.used = now;
            e.bytes += added;
            c.bytes += added;
        }
        None => {
            let mut e = Entry { used: now, bytes: size, ..Entry::default() };
            set(&mut e);
            c.entries.insert(key, e);
            c.bytes += size;
        }
    }
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

/// What is kept for one block: the preview's HTML and the editor's runs, each made when first asked for.
#[derive(Default)]
struct Entry {
    html: Option<String>,
    roles: Option<Arc<[RoleRun]>>,
    /// Its size in the cache's accounting, and when it was last asked for (`Cache::clock`).
    bytes: usize,
    used: u64,
}

#[derive(Default)]
struct Cache {
    entries: HashMap<(String, String), Entry>,
    bytes: usize,
    clock: u64,
}

impl Cache {
    /// Drops the entries asked for longest ago until a quarter of the cache is free: typing in a big
    /// block leaves one stale entry per keystroke, and those are the oldest, so what other blocks and
    /// the preview still use stays.
    fn evict(&mut self) {
        let mut by_age: Vec<(u64, usize)> = self.entries.values().map(|e| (e.used, e.bytes)).collect();
        by_age.sort_unstable();
        let (mut freed, mut cutoff) = (0, 0);
        for (used, bytes) in by_age {
            if self.bytes - freed <= CACHE_BYTES * 3 / 4 {
                break;
            }
            freed += bytes;
            cutoff = used;
        }
        self.entries.retain(|_, e| e.used > cutoff);
        self.bytes = self.entries.values().map(|e| e.bytes).sum();
    }
}

fn cache() -> &'static Mutex<Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default)
}

/// The languages offered in a menu, as `(token, display name)`: about thirty common ones first, in
/// the order of the list below, then every other language the highlighter has, alphabetically by
/// name. Each token is something the highlighter accepts in an info string and resolves to that
/// language (the common ones are the idiomatic spelling; the others the lowercase name or the
/// first file extension that round-trips). Plain text is not in it.
pub fn languages() -> &'static [(String, String)] {
    &language_list().0
}

/// How many of [`languages`] are the common ones, listed first.
pub fn common_language_count() -> usize {
    language_list().1
}

fn language_list() -> &'static (Vec<(String, String)>, usize) {
    static LIST: OnceLock<(Vec<(String, String)>, usize)> = OnceLock::new();
    LIST.get_or_init(|| {
        const COMMON: [&str; 31] = [
            "rust", "python", "js", "ts", "tsx", "json", "yaml", "toml", "html", "css", "scss", "sh", "c", "cpp", "cs",
            "java", "kotlin", "swift", "go", "ruby", "php", "sql", "md", "xml", "dockerfile", "lua", "hs", "objc", "diff",
            "tex", "make",
        ];
        let mut out: Vec<(String, String)> = Vec::new();
        for token in COMMON {
            if let Some(syntax) = find_syntax(token)
                && !out.iter().any(|(_, d)| *d == syntax.name)
            {
                out.push((token.to_owned(), syntax.name.clone()));
            }
        }
        let common = out.len();
        let mut rest: Vec<(String, String)> = Vec::new();
        for syntax in syntaxes().syntaxes() {
            if syntax.name == "Plain Text" || syntax.hidden || out.iter().any(|(_, d)| *d == syntax.name) {
                continue;
            }
            let lower = syntax.name.to_ascii_lowercase();
            let token = std::iter::once(lower.as_str())
                .chain(syntax.file_extensions.iter().map(String::as_str))
                .find(|t| info_token(t) == Some((0, t.len())) && !t.contains('`') && find_syntax(t).is_some_and(|f| f.name == syntax.name));
            if let Some(t) = token {
                rest.push((t.to_owned(), syntax.name.clone()));
            }
        }
        rest.sort_by_cached_key(|(_, d)| d.to_lowercase());
        out.extend(rest);
        (out, common)
    })
}

/// The role of a scope's own atoms, as the preview's stylesheet colours them (`preview_css`):
/// every rule whose atoms are all among the scope's first three matches, the one naming the most
/// atoms wins, a later one wins a tie. Keep this table in step with that stylesheet.
fn scope_role(atoms: &[&str]) -> Option<CodeRole> {
    use CodeRole::*;
    const RULES: [(&[&str], CodeRole); 27] = [
        (&["keyword"], Keyword),
        (&["storage"], Keyword),
        (&["string"], String),
        (&["constant"], Number),
        (&["entity", "name"], Function),
        (&["entity", "name", "type"], Type),
        (&["entity", "name", "class"], Type),
        (&["entity", "name", "struct"], Type),
        (&["entity", "name", "enum"], Type),
        (&["entity", "name", "interface"], Type),
        (&["entity", "name", "namespace"], Type),
        (&["support", "type"], Type),
        (&["support", "class"], Type),
        (&["entity", "other", "inherited-class"], Type),
        (&["entity", "other", "attribute-name"], Type),
        (&["entity", "name", "tag"], Tag),
        (&["markup", "deleted"], Tag),
        (&["invalid"], Invalid),
        (&["support", "function"], Function),
        (&["support", "constant", "property-name"], Function),
        (&["variable", "parameter"], Variable),
        (&["variable", "other", "readwrite"], Variable),
        (&["variable", "other", "member"], Variable),
        (&["variable", "language"], Keyword),
        (&["keyword", "operator", "word"], Keyword),
        (&["markup", "inserted"], String),
        (&["comment"], Comment),
    ];
    let mut best: Option<(usize, CodeRole)> = None;
    for (need, role) in RULES {
        if need.iter().all(|a| atoms.contains(a)) && best.is_none_or(|(n, _)| need.len() >= n) {
            best = Some((need.len(), role));
        }
    }
    best.map(|(_, r)| r)
}

/// `(role, is a comment)` of a scope; unstyled scopes (`source`, `meta`, `punctuation`...) have none.
fn role_of(scope: Scope) -> (Option<CodeRole>, bool) {
    let name = scope.build_string();
    let atoms: Vec<&str> = name.split('.').take(3).collect();
    if !STYLED.contains(&atoms[0]) {
        return (None, false);
    }
    (scope_role(&atoms), atoms[0] == "comment")
}

fn roles_uncached(syntax: &SyntaxReference, code: &str, deadline: Option<Instant>) -> Option<Vec<RoleRun>> {
    let ss = syntaxes();
    let mut state = ParseState::new(syntax);
    let mut stack = ScopeStack::new();
    // For each scope on the stack: its role, and whether it is a comment (which colours all inside it).
    let mut open: Vec<(Option<CodeRole>, bool)> = Vec::new();
    let mut comments = 0usize;
    let mut known: HashMap<Scope, (Option<CodeRole>, bool)> = HashMap::new();
    let mut runs: Vec<RoleRun> = Vec::new();
    let mut emit = |from: usize, to: usize, role: Option<CodeRole>| {
        let Some(role) = role else { return };
        if from >= to {
            return;
        }
        match runs.last_mut() {
            Some(last) if last.role == role && last.end as usize == from => last.end = to as u32,
            _ => runs.push(RoleRun { start: from as u32, end: to as u32, role }),
        }
    };
    let current = |open: &[(Option<CodeRole>, bool)], comments: usize| {
        if comments > 0 { Some(CodeRole::Comment) } else { open.iter().rev().find_map(|o| o.0) }
    };
    let mut base = 0;
    for line in LinesWithEndings::from(code) {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return None;
        }
        let ops = state.parse_line(line, ss).ok()?;
        let mut at = 0;
        for (i, op) in &ops {
            if *i > at {
                emit(base + at, base + *i, current(&open, comments));
                at = *i;
            }
            stack
                .apply_with_hook(op, |basic, _| match basic {
                    BasicScopeStackOp::Push(scope) => {
                        let r = *known.entry(scope).or_insert_with(|| role_of(scope));
                        comments += r.1 as usize;
                        open.push(r);
                    }
                    BasicScopeStackOp::Pop => {
                        if let Some(r) = open.pop() {
                            comments -= r.1 as usize;
                        }
                    }
                })
                .ok()?;
        }
        emit(base + at, base + line.len(), current(&open, comments));
        base += line.len();
    }
    Some(runs)
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
