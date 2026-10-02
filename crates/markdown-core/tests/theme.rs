//! Built-in themes: they parse, define every role, and meet WCAG AA where text is read.
use markdown_core::*;

const SOURCES: [&str; 3] = [
    include_str!("../themes/light.toml"),
    include_str!("../themes/dark.toml"),
    include_str!("../themes/sepia.toml"),
];

#[test]
fn builtins_parse_and_have_every_role() {
    let themes = builtin_themes();
    assert_eq!(themes.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["light", "dark", "sepia"]);
    assert_eq!(themes.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["Light", "Dark", "Sepia"]);
    let roles: Vec<&str> = themes[0].colors.all().iter().map(|r| r.0).collect();
    for (src, t) in SOURCES.iter().zip(&themes) {
        // The TOML file defines exactly the roles the struct has (a missing or extra role would
        // not parse), and each role is a distinct entry of the file.
        let doc: toml_probe::Table = toml_probe::parse(src);
        assert_eq!(doc.keys_in_colors.len(), roles.len(), "{}", t.id);
        for r in &roles {
            assert!(doc.keys_in_colors.iter().any(|k| k == r), "{}: role {r} missing", t.id);
        }
        assert_eq!(t.colors.all().len(), roles.len());
    }
    for r in [
        "background", "text", "markup", "heading", "link", "code_text", "code_background", "quote", "selection", "caret",
        "focus_dim", "pos_noun", "pos_verb", "pos_adjective", "pos_adverb", "pos_conjunction", "author_ai",
        "author_reference", "rule", "table_border",
    ] {
        assert!(roles.contains(&r), "role {r}");
    }
}

/// Just enough TOML reading to list the keys of `[colors]` without the core's own types.
mod toml_probe {
    pub struct Table {
        pub keys_in_colors: Vec<String>,
    }
    pub fn parse(src: &str) -> Table {
        let mut in_colors = false;
        let mut keys = Vec::new();
        for line in src.lines().map(str::trim) {
            if line.starts_with('[') {
                in_colors = line == "[colors]";
            } else if in_colors && let Some((k, _)) = line.split_once('=') {
                keys.push(k.trim().to_owned());
            }
        }
        Table { keys_in_colors: keys }
    }
}

#[test]
fn lookup_by_id() {
    assert_eq!(theme_by_id("sepia").unwrap().name, "Sepia");
    assert!(theme_by_id("nope").is_none());
    assert!(theme_by_id("dark").unwrap().is_dark);
    assert!(!theme_by_id("light").unwrap().is_dark);
}

#[test]
fn text_meets_wcag_aa() {
    for t in builtin_themes() {
        let c = &t.colors;
        let aa = |name: &str, fg: Color, bg: Color| {
            let r = contrast_ratio(fg, bg);
            assert!(r >= 4.5, "{}: {name} on its background is {r:.2}:1, below 4.5:1", t.id);
        };
        // Everything that is text, on the page.
        for (name, fg) in [
            ("text", c.text),
            ("heading", c.heading),
            ("link", c.link),
            ("code_text", c.code_text),
            ("quote", c.quote),
            ("pos_noun", c.pos_noun),
            ("pos_verb", c.pos_verb),
            ("pos_adjective", c.pos_adjective),
            ("pos_adverb", c.pos_adverb),
            ("pos_conjunction", c.pos_conjunction),
            ("author_ai", c.author_ai),
            ("author_reference", c.author_reference),
        ] {
            aa(name, fg, c.background);
        }
        // Code and links on the tinted code background, text on the selection.
        aa("code_text/code_background", c.code_text, c.code_background);
        aa("text/code_background", c.text, c.code_background);
        aa("link/code_background", c.link, c.code_background);
        aa("text/selection", c.text, c.selection.over(c.background));
        // The caret is a UI element: 3:1.
        assert!(contrast_ratio(c.caret, c.background) >= 3.0, "{}: caret", t.id);
        // The dim roles stay visible but recede from the text.
        for (name, dim) in [("markup", c.markup), ("focus_dim", c.focus_dim)] {
            let r = contrast_ratio(dim, c.background);
            assert!(r >= 1.5 && r < contrast_ratio(c.text, c.background), "{}: {name} is {r:.2}:1", t.id);
        }
        // Light themes have light pages and dark text, and the other way round.
        assert_eq!(t.is_dark, c.background.luminance() < c.text.luminance(), "{}", t.id);
        assert_eq!(t.is_dark, c.background.luminance() < 0.2, "{}", t.id);
    }
}

#[test]
fn colors_round_trip_through_hex() {
    for t in builtin_themes() {
        for (name, c) in t.colors.all() {
            assert_eq!(Color::from_hex(&c.to_hex()), Some(c), "{}: {name}", t.id);
        }
    }
    assert_eq!(Color::from_hex("#102030"), Some(Color { r: 16, g: 32, b: 48, a: 255 }));
    assert_eq!(Color::from_hex("#10203040"), Some(Color { r: 16, g: 32, b: 48, a: 64 }));
    for bad in ["", "102030", "#12345", "#12345g", "#1234567", "#\u{e9}0203"] {
        assert_eq!(Color::from_hex(bad), None, "{bad:?}");
    }
    assert!((contrast_ratio(Color::rgb(0, 0, 0), Color::rgb(255, 255, 255)) - 21.0).abs() < 1e-9);
}

#[test]
fn malformed_themes_are_errors() {
    let ok = SOURCES[0];
    assert!(Theme::from_toml(ok).is_ok());
    assert!(Theme::from_toml(&ok.replace("text = \"#26282B\"\n", "")).is_err(), "a missing role is an error");
    assert!(Theme::from_toml(&ok.replace("#26282B", "26282B")).is_err());
    assert!(Theme::from_toml(&format!("{ok}\nextra = \"#000000\"\n")).is_err(), "unknown roles are errors");
    assert!(Theme::from_toml("not toml [").is_err());
}
