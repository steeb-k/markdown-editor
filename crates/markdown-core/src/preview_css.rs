//! The stylesheet of the preview, the export and print: generated from a theme and the editor's
//! typography, so the preview reads like the same document.
//!
//! Colours come from the theme's roles (background, text, heading, link, code, quote, rule,
//! table border, selection). The syntax-highlighter's token classes (`.s-keyword`, ...) map onto
//! a small palette per kind of theme ([`syntax_palette`]), chosen to meet WCAG AA (4.5:1) on the
//! built-in themes' code backgrounds (a test checks it). The `@media print` section always
//! prints dark-on-white with the light palette, whatever the theme.

use std::fmt::Write;

use crate::theme::{builtin_themes, Color, Theme};

/// How the text is set: the editor's own settings, in CSS terms.
#[derive(Debug, Clone, PartialEq)]
pub struct Typography {
    /// A CSS `font-family` value for body text (a stack: the shell's font, then fallbacks).
    pub font_family: String,
    /// A CSS `font-family` value for code. When it equals `font_family` the body is monospaced
    /// and code is set at the same size; otherwise code is set a little smaller, as the editor does.
    pub mono_family: String,
    pub font_size_px: f64,
    /// Line height as a multiple of the font size.
    pub line_height: f64,
    /// The width of the text column in `ch` (the width of "0" in the body font).
    pub measure_ch: f64,
}

impl Default for Typography {
    fn default() -> Self {
        Self {
            font_family: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", system-ui, sans-serif".to_owned(),
            mono_family: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace".to_owned(),
            font_size_px: 17.0,
            line_height: 1.5,
            measure_ch: 72.0,
        }
    }
}

/// A theme and typography, as the standalone document's stylesheet wants them.
#[derive(Debug, Clone, PartialEq)]
pub struct PreviewStyle {
    pub theme: Theme,
    pub typography: Typography,
}

impl Default for PreviewStyle {
    fn default() -> Self {
        Self { theme: builtin_themes().remove(0), typography: Typography::default() }
    }
}

/// Colours of the highlighter's token classes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyntaxPalette {
    pub comment: Color,
    pub keyword: Color,
    pub string: Color,
    pub number: Color,
    pub function: Color,
    pub type_: Color,
    pub tag: Color,
    pub variable: Color,
}

impl SyntaxPalette {
    /// `(role name, colour)` for every colour, in a fixed order.
    pub fn all(&self) -> [(&'static str, Color); 8] {
        [
            ("comment", self.comment),
            ("keyword", self.keyword),
            ("string", self.string),
            ("number", self.number),
            ("function", self.function),
            ("type", self.type_),
            ("tag", self.tag),
            ("variable", self.variable),
        ]
    }
}

/// The token palette for light or dark themes. Calm: the colours sit near the text's own
/// lightness, hues do the telling-apart.
pub fn syntax_palette(dark: bool) -> SyntaxPalette {
    if dark {
        SyntaxPalette {
            comment: Color::rgb(0x8E, 0x96, 0xA3),
            keyword: Color::rgb(0xC7, 0x92, 0xEA),
            string: Color::rgb(0x98, 0xC3, 0x79),
            number: Color::rgb(0xF2, 0xA0, 0x65),
            function: Color::rgb(0x7A, 0xB7, 0xFF),
            type_: Color::rgb(0xE5, 0xC0, 0x7B),
            tag: Color::rgb(0xF0, 0x71, 0x78),
            variable: Color::rgb(0xE5, 0x8A, 0x7A),
        }
    } else {
        SyntaxPalette {
            comment: Color::rgb(0x5C, 0x64, 0x70),
            keyword: Color::rgb(0x7E, 0x34, 0x94),
            string: Color::rgb(0x24, 0x69, 0x2E),
            number: Color::rgb(0x9A, 0x42, 0x13),
            function: Color::rgb(0x1D, 0x5A, 0xAB),
            type_: Color::rgb(0x76, 0x53, 0x0A),
            tag: Color::rgb(0xA0, 0x23, 0x50),
            variable: Color::rgb(0x92, 0x30, 0x1F),
        }
    }
}

/// The preview's stylesheet for `theme` set in `typography`.
pub fn preview_css(theme: &Theme, typography: &Typography) -> String {
    let c = &theme.colors;
    let t = typography;
    let pal = syntax_palette(theme.is_dark);
    let light = syntax_palette(false);
    let mono_scale = if t.font_family == t.mono_family { 1.0 } else { 0.92 };
    let mut css = String::with_capacity(9000);
    let w = &mut css;
    let _ = write!(
        w,
        ":root {{
  color-scheme: {scheme};
  --bg: {bg}; --text: {text}; --heading: {heading}; --link: {link};
  --code-text: {code_text}; --code-bg: {code_bg}; --quote: {quote};
  --rule: {rule}; --border: {border}; --markup: {markup}; --selection: {selection};
  --tok-comment: {t_comment}; --tok-keyword: {t_keyword}; --tok-string: {t_string}; --tok-number: {t_number};
  --tok-function: {t_function}; --tok-type: {t_type}; --tok-tag: {t_tag}; --tok-variable: {t_variable};
  --chrome-top: 0px; --chrome-bottom: 0px;
}}
",
        scheme = if theme.is_dark { "dark" } else { "light" },
        bg = c.background.to_hex(),
        text = c.text.to_hex(),
        heading = c.heading.to_hex(),
        link = c.link.to_hex(),
        code_text = c.code_text.to_hex(),
        code_bg = c.code_background.to_hex(),
        quote = c.quote.to_hex(),
        rule = c.rule.to_hex(),
        border = c.table_border.to_hex(),
        markup = c.markup.to_hex(),
        selection = c.selection.to_hex(),
        t_comment = pal.comment.to_hex(),
        t_keyword = pal.keyword.to_hex(),
        t_string = pal.string.to_hex(),
        t_number = pal.number.to_hex(),
        t_function = pal.function.to_hex(),
        t_type = pal.type_.to_hex(),
        t_tag = pal.tag.to_hex(),
        t_variable = pal.variable.to_hex(),
    );
    let _ = write!(
        w,
        "html {{ background: var(--bg); }}
body {{
  margin: 0; background: var(--bg); color: var(--text);
  font-family: {family}; font-size: {size}px; line-height: {lh};
  -webkit-font-smoothing: antialiased; -webkit-text-size-adjust: 100%;
  font-kerning: normal; text-rendering: optimizeLegibility;
}}
.md {{
  box-sizing: content-box; max-width: {measure}ch; margin: 0 auto;
  padding: calc(var(--chrome-top) + 52px) 28px calc(var(--chrome-bottom) + 96px);
  overflow-wrap: break-word;
}}
::selection {{ background: var(--selection); }}
.md > :first-child {{ margin-top: 0; }}
p, ul, ol, dl, pre, blockquote, table {{ margin: 0 0 1em; }}
h1, h2, h3, h4, h5, h6 {{
  color: var(--heading); font-weight: 700; line-height: 1.3; margin: 0.35em 0 0.4em;
  scroll-margin-top: calc(var(--chrome-top) + 16px);
}}
h1 {{ font-size: 1.7em; margin-top: 0.55em; }}
h2 {{ font-size: 1.4em; margin-top: 0.55em; }}
h3 {{ font-size: 1.2em; margin-top: 0.55em; }}
h4 {{ font-size: 1.1em; }}
h5, h6 {{ font-size: 1em; }}
h6 {{ color: var(--quote); }}
a {{ color: var(--link); text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 0.18em; text-decoration-color: color-mix(in srgb, var(--link) 45%, transparent); }}
a:hover {{ text-decoration-color: var(--link); }}
strong {{ font-weight: 700; }}
del {{ text-decoration-thickness: 1px; }}
ul {{ padding-left: 1.7em; }}
ol {{ padding-left: 2em; }}
li {{ margin: 0.15em 0; }}
li > p {{ margin-bottom: 0.5em; }}
li > ul, li > ol {{ margin: 0.15em 0 0.15em; }}
li.task-list-item {{ list-style: none; }}
li.task-list-item > input[type=checkbox], li.task-list-item > p:first-child > input[type=checkbox] {{
  margin: 0 0.5em 0.1em -1.35em; vertical-align: middle; accent-color: var(--link);
}}
blockquote {{ padding: 0 0 0 1.1em; border-left: 3px solid var(--rule); color: var(--quote); }}
blockquote > :last-child {{ margin-bottom: 0; }}
hr {{ border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }}
img {{ max-width: 100%; height: auto; border-radius: 4px; }}
code, pre {{ font-family: {mono}; font-size: {mono_scale}em; }}
:not(pre) > code {{ background: var(--code-bg); color: var(--code-text); padding: 0.1em 0.35em; border-radius: 4px; }}
pre {{ background: var(--code-bg); padding: 0.85em 1.1em; border-radius: 6px; overflow-x: auto; line-height: 1.4; tab-size: 4; }}
pre code {{ background: none; padding: 0; color: var(--text); font-size: 1em; }}
table {{ border-collapse: collapse; max-width: 100%; }}
th, td {{ border: 1px solid var(--border); padding: 0.4em 0.8em; vertical-align: top; }}
th {{ background: var(--code-bg); font-weight: 700; text-align: left; }}
.footnotes {{ margin-top: 3em; padding-top: 0.5em; border-top: 1px solid var(--rule); font-size: 0.9em; color: var(--quote); }}
.footnotes ol {{ padding-left: 1.5em; }}
.footnotes li {{ scroll-margin-top: calc(var(--chrome-top) + 16px); }}
.footnotes p {{ margin-bottom: 0.4em; }}
.footnote-ref {{ font-size: 0.75em; line-height: 0; }}
.footnote-ref a, .footnote-backref {{ text-decoration: none; }}
.unparsed {{ white-space: pre-wrap; }}
",
        family = font_stack(&t.font_family),
        size = fmt_num(t.font_size_px),
        lh = fmt_num(t.line_height),
        measure = fmt_num(t.measure_ch),
        mono = font_stack(&t.mono_family),
        mono_scale = fmt_num(mono_scale),
    );
    // Task boxes drawn like the editor's (a disabled control is drawn dimmed by WebKit).
    w.push_str(
        "li.task-list-item input[type=checkbox] {
  -webkit-appearance: none; appearance: none; box-sizing: border-box; width: 0.9em; height: 0.9em;
  border: 1.5px solid var(--markup); border-radius: 0.22em; background: transparent; vertical-align: -0.08em; opacity: 1;
  -webkit-print-color-adjust: exact; print-color-adjust: exact;
}
li.task-list-item input[type=checkbox]:checked {
  border-color: var(--link); background: var(--link) center / 80% no-repeat url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2.6 6.3l2.3 2.3 4.6-5.1' fill='none' stroke='white' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\");
}
",
    );
    // Token classes (prefix `s-`, see `highlight`). Specific selectors follow general ones.
    w.push_str(
        "/* code tokens */
.md pre code .s-keyword, .md pre code .s-storage { color: var(--tok-keyword); }
.md pre code .s-string { color: var(--tok-string); }
.md pre code .s-constant { color: var(--tok-number); }
.md pre code .s-entity.s-name { color: var(--tok-function); }
.md pre code .s-entity.s-name.s-type, .md pre code .s-entity.s-name.s-class, .md pre code .s-entity.s-name.s-struct,
.md pre code .s-entity.s-name.s-enum, .md pre code .s-entity.s-name.s-interface, .md pre code .s-entity.s-name.s-namespace,
.md pre code .s-support.s-type, .md pre code .s-support.s-class, .md pre code .s-entity.s-other.s-inherited-class,
.md pre code .s-entity.s-other.s-attribute-name { color: var(--tok-type); }
.md pre code .s-entity.s-name.s-tag, .md pre code .s-markup.s-deleted, .md pre code .s-invalid { color: var(--tok-tag); }
.md pre code .s-support.s-function, .md pre code .s-support.s-constant.s-property-name, .md pre code .s-meta.s-function-call .s-support { color: var(--tok-function); }
.md pre code .s-variable.s-parameter, .md pre code .s-variable.s-other.s-readwrite, .md pre code .s-variable.s-other.s-member { color: var(--tok-variable); }
.md pre code .s-variable.s-language, .md pre code .s-keyword.s-operator.s-word { color: var(--tok-keyword); }
.md pre code .s-markup.s-inserted { color: var(--tok-string); }
.md pre code .s-markup.s-heading, .md pre code .s-markup.s-bold { font-weight: 700; }
.md pre code .s-markup.s-italic { font-style: italic; }
.md pre code .s-comment, .md pre code .s-comment [class] { color: var(--tok-comment); }
.md pre code .s-comment { font-style: italic; }
",
    );
    // Print: light, whatever the theme; pagination rules.
    let _ = write!(
        w,
        "@page {{ margin: 18mm 16mm; }}
@media print {{
  :root {{
    color-scheme: light;
    --bg: #FFFFFF; --text: #000000; --heading: #000000; --link: #1A4F9C;
    --code-text: #4A2F7A; --code-bg: #F3F3F1; --quote: #3A3F47; --rule: #BDBFC3; --border: #9A9CA1; --markup: #777777;
    --selection: #CCE0FF; --chrome-top: 0px; --chrome-bottom: 0px;
    --tok-comment: {p_comment}; --tok-keyword: {p_keyword}; --tok-string: {p_string}; --tok-number: {p_number};
    --tok-function: {p_function}; --tok-type: {p_type}; --tok-tag: {p_tag}; --tok-variable: {p_variable};
  }}
  html, body {{ background: #FFFFFF !important; color: #000000 !important; }}
  body {{ font-size: 11pt; line-height: {lh}; }}
  .md {{ max-width: none; margin: 0; padding: 0; }}
  h1, h2, h3, h4, h5, h6 {{ break-after: avoid; page-break-after: avoid; break-inside: avoid; page-break-inside: avoid; }}
  /* WebKit's print pagination ignores break-after: avoid. A heading carries an invisible tail as
     tall as three lines of text (its own bottom padding), which it may not be split from, and
     gives the room back below (a negative margin): a heading that would end a page moves to the
     next one with the lines that follow it. (WebKit leaves an invisible, clipped copy of a block
     it moves to the next page in the foot margin of the page before: the PDF's text layer holds
     such a heading twice.) */
  h1, h2, h3, h4, h5, h6 {{ padding-bottom: {keep}pt; margin-bottom: calc(0.4em - {keep}pt); }}
  p, li, blockquote {{ orphans: 3; widows: 3; }}
  pre, table, img, tr, blockquote, .footnotes li {{ break-inside: avoid; page-break-inside: avoid; }}
  pre {{ white-space: pre-wrap; word-break: break-word; overflow: visible; }}
  thead {{ display: table-header-group; }}
  img {{ max-width: 100%; }}
  a {{ color: inherit; text-decoration: underline; }}
  a[href]::after {{ content: none !important; }}
  pre, code, th, :not(pre) > code {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
  .footnotes {{ break-before: avoid; }}
}}
",
        p_comment = light.comment.to_hex(),
        p_keyword = light.keyword.to_hex(),
        p_string = light.string.to_hex(),
        p_number = light.number.to_hex(),
        p_function = light.function.to_hex(),
        p_type = light.type_.to_hex(),
        p_tag = light.tag.to_hex(),
        p_variable = light.variable.to_hex(),
        lh = fmt_num(t.line_height),
        keep = fmt_num((3.0 * t.line_height * PRINT_FONT_PT).round()),
    );
    css
}

/// The body text size in print.
const PRINT_FONT_PT: f64 = 11.0;

/// A `font-family` value as given (a stack of quoted names and generic families), minus anything
/// that could end the declaration, the rule or the `<style>` element it is written into: an
/// installed font's name is not trusted to be tidy.
fn font_stack(stack: &str) -> String {
    let clean: String = stack.chars().filter(|c| !matches!(c, '{' | '}' | ';' | '<' | '>' | '\\' | '@') && !c.is_control()).collect();
    if clean.trim().is_empty() { "sans-serif".to_owned() } else { clean }
}

/// A number as short CSS text: `17`, `1.5`, `0.92`.
fn fmt_num(v: f64) -> String {
    let s = format!("{v:.3}");
    s.trim_end_matches('0').trim_end_matches('.').to_owned()
}
