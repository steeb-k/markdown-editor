//! Templates: the TOML (every field round-trips, bad values name their key), the CSS (the default spec is today's
//! stylesheet byte for byte, each field lands in a rule for the right selector) and the built-in packages.
use markdown_core::template::*;
use markdown_core::{builtin_themes, preview_css, Typography};
use proptest::prelude::*;

fn theme() -> markdown_core::Theme {
    builtin_themes().remove(0)
}

fn css(spec: &TemplateSpec) -> String {
    template_css(spec, &theme(), &Typography::default())
}

fn one(kind: ElementKind, style: ElementStyle) -> TemplateSpec {
    let mut spec = TemplateSpec::default();
    spec.elements.insert(kind, style);
    spec
}

/// The CSS the template adds after the base: what follows the last token rule, up to the print block.
fn added(spec: &TemplateSpec) -> String {
    let full = css(spec);
    let base = css(&TemplateSpec::default());
    let head = base.find("@page {").expect("print block");
    assert!(full.starts_with(&base[..head]), "the base comes first");
    assert!(full.ends_with(&base[head..]), "the print block comes last");
    full[head..full.len() - (base.len() - head)].to_owned()
}

fn maximal() -> Template {
    let mut spec = TemplateSpec {
        page: PageStyle {
            measure_ch: Some(64.5),
            side_padding: Some(Length::new(2.0, Unit::Em)),
            background: Some(ColorRef::Fixed(Rgb(250, 248, 240))),
            align: Some(Align::Justify),
        },
        ..Default::default()
    };
    for (i, kind) in ElementKind::all().into_iter().enumerate() {
        let i = i as u16;
        spec.elements.insert(
            kind,
            ElementStyle {
                font_family: Some([FontFamily::Body, FontFamily::Mono, FontFamily::Named("Iowan \"Old\" Style".into())][i as usize % 3].clone()),
                font_size: Some(Length::new(1.0 + i as f64 / 10.0, Unit::Em)),
                weight: Some(100 + 100 * (i % 9)),
                italic: Some(i.is_multiple_of(2)),
                color: Some(ColorRef::Theme(ThemeColor::ALL[i as usize % ThemeColor::ALL.len()])),
                background: Some(ColorRef::Fixed(Rgb(i as u8, 2, 255))),
                space_above: Some(Length::new(12.0, Unit::Px)),
                space_below: Some(Length::new(0.75, Unit::Pt)),
                line_height: Some(1.25 + i as f64 / 100.0),
                align: Some(Align::ALL[i as usize % 4]),
                indent: Some(Length::new(1.5, Unit::Em)),
                letter_spacing: Some(Length::new(-0.02, Unit::Em)),
                transform: Some(Transform::ALL[i as usize % 3]),
                decoration: Some(Decoration::ALL[i as usize % 2]),
                border: Some(Border {
                    side: Side::ALL[i as usize % 4],
                    style: BorderStyle::ALL[i as usize % 3],
                    width: Length::new(2.0, Unit::Px),
                    color: ColorRef::Theme(ThemeColor::Rule),
                }),
                radius: Some(Length::new(4.0, Unit::Px)),
                numbered: Some(i.is_multiple_of(3)),
                marker: Some(Marker::ALL[i as usize % Marker::ALL.len()]),
            },
        );
    }
    Template {
        meta: TemplateMeta {
            name: "Everything \"quoted\"".into(),
            author: "Me".into(),
            version: "3".into(),
            description: "Line one.\nLine two # not a comment".into(),
        },
        spec,
    }
}

// ----- TOML -------------------------------------------------------------------------------------------------------

#[test]
fn every_field_round_trips() {
    let t = maximal();
    let text = t.to_toml();
    assert_eq!(Template::parse(&text).unwrap(), t);
    assert_eq!(Template::parse(&text).unwrap().to_toml(), text, "the text is stable");
}

#[test]
fn the_layout_is_stable_and_readable() {
    let mut spec = TemplateSpec::default();
    spec.page.measure_ch = Some(60.0);
    spec.elements.insert(
        ElementKind::H2,
        ElementStyle {
            font_size: Some(Length::new(1.4, Unit::Em)),
            color: Some(ColorRef::Theme(ThemeColor::Link)),
            border: Some(Border {
                side: Side::Bottom,
                style: BorderStyle::Solid,
                width: Length::new(1.0, Unit::Px),
                color: ColorRef::Fixed(Rgb(0x1A, 0x4F, 0x9C)),
            }),
            ..Default::default()
        },
    );
    let t = Template { meta: TemplateMeta { name: "N".into(), ..Default::default() }, spec };
    assert_eq!(
        t.to_toml(),
        "[template]\nname = \"N\"\nauthor = \"\"\nversion = \"\"\ndescription = \"\"\n\n[page]\nmeasure_ch = 60.0\n\n\
         [elements.h2]\nfont_size = \"1.4em\"\ncolor = \"theme:link\"\n\
         border = { side = \"bottom\", style = \"solid\", width = \"1px\", color = \"#1A4F9C\" }\n"
    );
}

#[test]
fn empty_and_unknown_keys_are_fine() {
    assert_eq!(Template::parse("").unwrap(), Template::default());
    let t = Template::parse(
        "future = 1\n[template]\nname = \"X\"\nlicence = \"MIT\"\nversion = 2\n[page]\nfuture = true\nmeasure_ch = 70\n\
         [elements.h1]\nweight = 700\nsparkle = \"yes\"\n[elements.marquee]\ncolor = \"nonsense\"\n[other]\nx = 1\n",
    )
    .unwrap();
    assert_eq!(t.meta.name, "X");
    assert_eq!(t.meta.version, "2");
    assert_eq!(t.spec.page.measure_ch, Some(70.0));
    assert_eq!(t.spec.elements.len(), 1);
    assert_eq!(t.spec.elements[&ElementKind::H1].weight, Some(700));
}

#[test]
fn bad_values_name_their_key() {
    let bad = [
        ("[elements.h1]\nfont_size = \"big\"", "elements.h1.font_size"),
        ("[elements.h1]\nfont_size = 12", "elements.h1.font_size"),
        ("[elements.h1]\nweight = 1000", "elements.h1.weight"),
        ("[elements.h1]\nweight = \"bold\"", "elements.h1.weight"),
        ("[elements.paragraph]\ncolor = \"blue\"", "elements.paragraph.color"),
        ("[elements.paragraph]\ncolor = \"theme:nope\"", "elements.paragraph.color"),
        ("[elements.paragraph]\nbackground = \"#12345\"", "elements.paragraph.background"),
        ("[elements.link]\nitalic = \"yes\"", "elements.link.italic"),
        ("[elements.link]\nalign = \"middle\"", "elements.link.align"),
        ("[elements.link]\ntransform = \"shout\"", "elements.link.transform"),
        ("[elements.link]\ndecoration = \"blink\"", "elements.link.decoration"),
        ("[elements.link]\nline_height = \"tall\"", "elements.link.line_height"),
        ("[elements.link]\nspace_above = \"1\"", "elements.link.space_above"),
        ("[elements.link]\nspace_below = \"NaNem\"", "elements.link.space_below"),
        ("[elements.link]\nindent = \"1 furlong\"", "elements.link.indent"),
        ("[elements.link]\nletter_spacing = \"x\"", "elements.link.letter_spacing"),
        ("[elements.link]\nradius = \"x\"", "elements.link.radius"),
        ("[elements.link]\nfont_family = \"\"", "elements.link.font_family"),
        ("[elements.bullet_list]\nmarker = \"star\"", "elements.bullet_list.marker"),
        ("[elements.h1]\nnumbered = 1", "elements.h1.numbered"),
        ("[elements.table]\nborder = \"thin\"", "elements.table.border"),
        ("[elements.table]\nborder = { side = \"top\", width = \"1px\" }", "elements.table.border.color"),
        ("[elements.table]\nborder = { side = \"diagonal\", width = \"1px\", color = \"#000000\" }", "elements.table.border.side"),
        ("[elements.table]\nborder = { side = \"top\", style = \"wavy\", width = \"1px\", color = \"#000000\" }", "elements.table.border.style"),
        ("[elements]\nh1 = 3", "elements.h1"),
        ("[page]\nmeasure_ch = \"wide\"", "page.measure_ch"),
        ("[page]\nside_padding = \"wide\"", "page.side_padding"),
        ("[page]\nbackground = 3", "page.background"),
        ("[page]\nalign = \"x\"", "page.align"),
        ("[template]\nname = 3", "template.name"),
        ("template = 3", "template"),
    ];
    for (src, key) in bad {
        match Template::parse(src) {
            Err(TemplateError::Value { key: k, message }) => {
                assert_eq!(k, key, "{src}");
                assert!(!message.is_empty());
            }
            other => panic!("{src}: {other:?}"),
        }
    }
    assert!(matches!(Template::parse("[elements.h1\n"), Err(TemplateError::Syntax(m)) if !m.is_empty()));
}

#[test]
fn values_are_read_leniently() {
    let t = Template::parse(
        "[page]\nbackground = \"#abcdef\"\nalign = \"CENTER\"\n[elements.link]\ncolor = \" Theme:Code-Bg \"\nfont_size = \" 12 PX \"\nfont_family = \"MONO\"\nline_height = 2\n",
    )
    .unwrap();
    assert_eq!(t.spec.page.background, Some(ColorRef::Fixed(Rgb(0xAB, 0xCD, 0xEF))));
    assert_eq!(t.spec.page.align, Some(Align::Center));
    let link = &t.spec.elements[&ElementKind::Link];
    assert_eq!(link.color, Some(ColorRef::Theme(ThemeColor::CodeBackground)));
    assert_eq!(link.font_size, Some(Length::new(12.0, Unit::Px)));
    assert_eq!(link.font_family, Some(FontFamily::Mono));
    assert_eq!(link.line_height, Some(2.0));
}

#[test]
fn element_kinds_have_unique_keys_and_selectors() {
    let kinds = ElementKind::all();
    assert_eq!(kinds.len(), 23);
    assert!(kinds.windows(2).all(|w| w[0] < w[1]), "in declaration order");
    for k in &kinds {
        assert_eq!(ElementKind::from_key(k.key()), Some(*k));
        assert!(!k.name().is_empty() && !k.selector().is_empty());
    }
    let mut keys: Vec<_> = kinds.iter().map(|k| k.key()).collect();
    keys.sort();
    keys.dedup();
    assert_eq!(keys.len(), kinds.len());
    assert_eq!(ElementKind::H3.selector(), "h3");
    assert_eq!(ElementKind::InlineCode.selector(), ":not(pre) > code");
    assert_eq!(ElementKind::TaskItem.selector(), "li.task-list-item");
    assert_eq!(ElementKind::TableHeader.key(), "table_header");
    assert_eq!(ElementKind::Footnotes.selector(), ".footnotes");
}

// ----- CSS --------------------------------------------------------------------------------------------------------

#[test]
fn the_default_spec_is_todays_stylesheet_byte_for_byte() {
    let fixture = include_str!("fixtures/preview_css_default.css");
    assert_eq!(preview_css(&theme(), &Typography::default()), fixture);
    assert_eq!(css(&TemplateSpec::default()), fixture);
    // An element with nothing set writes nothing either.
    assert_eq!(css(&one(ElementKind::H1, ElementStyle::default())), fixture);
}

#[test]
fn a_template_goes_between_the_base_and_the_print_block() {
    let spec = one(ElementKind::Paragraph, ElementStyle { color: Some(ColorRef::Theme(ThemeColor::Text)), ..Default::default() });
    assert_eq!(added(&spec), "p { color: var(--text); }\n");
}

#[test]
fn each_field_is_a_declaration_of_the_right_rule() {
    let t = Typography::default();
    let cases: Vec<(ElementKind, ElementStyle, String)> = vec![
        (ElementKind::Body, ElementStyle { font_family: Some(FontFamily::Body), ..Default::default() }, format!("body {{ font-family: {}; }}", t.font_family)),
        (ElementKind::Strong, ElementStyle { font_family: Some(FontFamily::Mono), ..Default::default() }, format!("strong {{ font-family: {}; }}", t.mono_family)),
        (ElementKind::Paragraph, ElementStyle { font_family: Some(FontFamily::Named("Charter".into())), ..Default::default() }, "p { font-family: \"Charter\", serif; }".into()),
        (ElementKind::Paragraph, ElementStyle { font_family: Some(FontFamily::Named("Avenir Next".into())), ..Default::default() }, "p { font-family: \"Avenir Next\", sans-serif; }".into()),
        (ElementKind::InlineCode, ElementStyle { font_family: Some(FontFamily::Named("Fira Code".into())), ..Default::default() }, ":not(pre) > code { font-family: \"Fira Code\", monospace; }".into()),
        (ElementKind::Paragraph, ElementStyle { font_family: Some(FontFamily::Named("Charter, Georgia, serif".into())), ..Default::default() }, "p { font-family: Charter, Georgia, serif; }".into()),
        (ElementKind::H1, ElementStyle { font_size: Some(Length::new(1.4, Unit::Em)), ..Default::default() }, "h1 { font-size: 1.4em; }".into()),
        (ElementKind::H2, ElementStyle { weight: Some(300), ..Default::default() }, "h2 { font-weight: 300; }".into()),
        (ElementKind::Emphasis, ElementStyle { italic: Some(false), ..Default::default() }, "em { font-style: normal; }".into()),
        (ElementKind::Strong, ElementStyle { italic: Some(true), ..Default::default() }, "strong { font-style: italic; }".into()),
        (ElementKind::BlockQuote, ElementStyle { background: Some(ColorRef::Theme(ThemeColor::CodeBackground)), ..Default::default() }, "blockquote { background: var(--code-bg); }".into()),
        (ElementKind::Image, ElementStyle { space_above: Some(Length::new(12.0, Unit::Px)), space_below: Some(Length::new(0.5, Unit::Pt)), ..Default::default() }, "img { margin-top: 12px; margin-bottom: 0.5pt; }".into()),
        (ElementKind::Table, ElementStyle { line_height: Some(1.6), ..Default::default() }, "table { line-height: 1.6; }".into()),
        (ElementKind::TableHeader, ElementStyle { align: Some(Align::Center), ..Default::default() }, "th { text-align: center; }".into()),
        (ElementKind::Paragraph, ElementStyle { indent: Some(Length::new(1.5, Unit::Em)), ..Default::default() }, "p { text-indent: 1.5em; }".into()),
        (ElementKind::Tag, ElementStyle { letter_spacing: Some(Length::new(0.05, Unit::Em)), ..Default::default() }, ".tag { letter-spacing: 0.05em; }".into()),
        (ElementKind::H1, ElementStyle { transform: Some(Transform::Uppercase), ..Default::default() }, "h1 { text-transform: uppercase; }".into()),
        (ElementKind::H6, ElementStyle { transform: Some(Transform::SmallCaps), ..Default::default() }, "h6 { font-variant: small-caps; }".into()),
        (ElementKind::H5, ElementStyle { transform: Some(Transform::None), ..Default::default() }, "h5 { text-transform: none; font-variant: normal; }".into()),
        (ElementKind::Link, ElementStyle { decoration: Some(Decoration::None), ..Default::default() }, "a { text-decoration: none; }".into()),
        (ElementKind::Link, ElementStyle { decoration: Some(Decoration::Underline), ..Default::default() }, "a { text-decoration: underline; }".into()),
        (ElementKind::Rule, ElementStyle { border: Some(Border { side: Side::Top, style: BorderStyle::Dashed, width: Length::new(1.0, Unit::Px), color: ColorRef::Theme(ThemeColor::Rule) }), ..Default::default() }, "hr { border-top: 1px dashed var(--rule); }".into()),
        (ElementKind::BlockQuote, ElementStyle { border: Some(Border { side: Side::Left, style: BorderStyle::Solid, width: Length::new(4.0, Unit::Px), color: ColorRef::Fixed(Rgb(1, 2, 3)) }), ..Default::default() }, "blockquote { border-left: 4px solid #010203; }".into()),
        (ElementKind::CodeBlock, ElementStyle { radius: Some(Length::new(0.0, Unit::Px)), ..Default::default() }, "pre { border-radius: 0px; }".into()),
        (ElementKind::TaskItem, ElementStyle { color: Some(ColorRef::Theme(ThemeColor::Quote)), ..Default::default() }, "li.task-list-item { color: var(--quote); }".into()),
        (ElementKind::Footnotes, ElementStyle { font_size: Some(Length::new(0.8, Unit::Em)), ..Default::default() }, ".footnotes { font-size: 0.8em; }".into()),
        (ElementKind::BulletList, ElementStyle { marker: Some(Marker::Square), ..Default::default() }, "ul { list-style-type: square; }".into()),
        (ElementKind::NumberedList, ElementStyle { marker: Some(Marker::LowerRoman), ..Default::default() }, "ol { list-style-type: lower-roman; }".into()),
        // A marker means nothing to an element that is not a list.
        (ElementKind::Paragraph, ElementStyle { marker: Some(Marker::Disc), numbered: Some(true), ..Default::default() }, String::new()),
    ];
    for (kind, style, want) in cases {
        let got = added(&one(kind, style));
        if want.is_empty() {
            assert_eq!(got, "");
        } else {
            assert_eq!(got.trim_end(), want);
        }
    }
}

#[test]
fn several_fields_share_one_rule_in_a_fixed_order() {
    let style = ElementStyle {
        radius: Some(Length::new(2.0, Unit::Px)),
        color: Some(ColorRef::Fixed(Rgb(0, 0, 0))),
        font_size: Some(Length::new(10.0, Unit::Pt)),
        ..Default::default()
    };
    assert_eq!(added(&one(ElementKind::H4, style)), "h4 { font-size: 10pt; color: #000000; border-radius: 2px; }\n");
}

#[test]
fn rules_come_in_element_kind_order() {
    let mut spec = TemplateSpec::default();
    for kind in [ElementKind::Tag, ElementKind::Body, ElementKind::H3] {
        spec.elements.insert(kind, ElementStyle { weight: Some(400), ..Default::default() });
    }
    assert_eq!(added(&spec), "body { font-weight: 400; }\nh3 { font-weight: 400; }\n.tag { font-weight: 400; }\n");
}

#[test]
fn the_page_overrides_the_column_and_the_background() {
    let spec = TemplateSpec {
        page: PageStyle {
            measure_ch: Some(60.0),
            side_padding: Some(Length::new(64.0, Unit::Px)),
            background: Some(ColorRef::Fixed(Rgb(0xFA, 0xF8, 0xF0))),
            align: Some(Align::Justify),
        },
        ..Default::default()
    };
    let got = added(&spec);
    assert_eq!(
        got,
        ".md { max-width: 60ch; padding-left: 64px; padding-right: 64px; }\nhtml, body { background: #FAF8F0; }\nbody { text-align: justify; }\n"
    );
}

#[test]
fn theme_colours_follow_the_theme_and_fixed_ones_do_not() {
    let spec = one(
        ElementKind::Link,
        ElementStyle { color: Some(ColorRef::Theme(ThemeColor::CodeText)), background: Some(ColorRef::Fixed(Rgb(0x1A, 0x4F, 0x9C))), ..Default::default() },
    );
    // The same text for every theme: only the variables' definitions differ.
    for theme in builtin_themes() {
        let out = template_css(&spec, &theme, &Typography::default());
        assert!(out.contains("a { color: var(--code-text); background: #1A4F9C; }\n"), "{}", theme.id);
    }
    for (c, var) in [
        (ThemeColor::Text, "var(--text)"),
        (ThemeColor::Heading, "var(--heading)"),
        (ThemeColor::Link, "var(--link)"),
        (ThemeColor::Quote, "var(--quote)"),
        (ThemeColor::Rule, "var(--rule)"),
        (ThemeColor::Border, "var(--border)"),
        (ThemeColor::CodeText, "var(--code-text)"),
        (ThemeColor::CodeBackground, "var(--code-bg)"),
        (ThemeColor::Background, "var(--bg)"),
        (ThemeColor::Markup, "var(--markup)"),
    ] {
        assert_eq!(ColorRef::Theme(c).css(), var);
    }
    // Every variable a template can name is defined by the base.
    let base = css(&TemplateSpec::default());
    for c in ThemeColor::ALL {
        assert!(base.contains(&format!("{}: #", c.css_var())), "{}", c.word());
    }
}

#[test]
fn numbered_headings_count_and_reset() {
    let mut spec = TemplateSpec::default();
    for kind in [ElementKind::H1, ElementKind::H2, ElementKind::H3] {
        spec.elements.insert(kind, ElementStyle { numbered: Some(true), ..Default::default() });
    }
    assert_eq!(
        added(&spec),
        ".md { counter-reset: md-h1 md-h2 md-h3; }\n\
         h1 { counter-increment: md-h1; counter-reset: md-h2 md-h3; }\n\
         h1::before { content: counter(md-h1) \". \"; }\n\
         h2 { counter-increment: md-h2; counter-reset: md-h3; }\n\
         h2::before { content: counter(md-h1) \".\" counter(md-h2) \" \"; }\n\
         h3 { counter-increment: md-h3; }\n\
         h3::before { content: counter(md-h1) \".\" counter(md-h2) \".\" counter(md-h3) \" \"; }\n"
    );
    // Only h2 numbered: a lone level, and the ones above are not counted.
    let spec = one(ElementKind::H2, ElementStyle { numbered: Some(true), ..Default::default() });
    let got = added(&spec);
    assert!(got.contains("h2 { counter-increment: md-h2; }"), "{got}");
    assert!(got.contains("h2::before { content: counter(md-h2) \". \"; }"), "{got}");
    // Off, or on a heading that is not counted: nothing.
    assert_eq!(added(&one(ElementKind::H1, ElementStyle { numbered: Some(false), ..Default::default() })), "");
    assert_eq!(added(&one(ElementKind::H4, ElementStyle { numbered: Some(true), ..Default::default() })), "");
}

#[test]
fn dash_markers_replace_the_marker_of_every_item_but_tasks() {
    let spec = one(ElementKind::BulletList, ElementStyle { marker: Some(Marker::Dash), ..Default::default() });
    assert_eq!(added(&spec), "ul > li:not(.task-list-item)::marker { content: \"\u{2013} \"; }\n");
}

#[test]
fn code_block_family_and_colour_reach_the_code_inside() {
    let spec = one(
        ElementKind::CodeBlock,
        ElementStyle { font_family: Some(FontFamily::Named("Menlo".into())), color: Some(ColorRef::Theme(ThemeColor::Heading)), ..Default::default() },
    );
    assert_eq!(
        added(&spec),
        "pre { font-family: \"Menlo\", monospace; color: var(--heading); }\npre code { font-family: \"Menlo\", monospace; color: var(--heading); }\n"
    );
}

#[test]
fn hostile_font_names_cannot_leave_the_declaration() {
    let spec = one(ElementKind::Body, ElementStyle { font_family: Some(FontFamily::Named("A\"; } body { x: y; /*".into())), ..Default::default() });
    let got = added(&spec);
    assert_eq!(got.matches('{').count(), 1, "{got}");
    assert_eq!(got.matches('}').count(), 1, "{got}");
}

// ----- the built-in packages -----------------------------------------------------------------------------------------

const BUILTINS: [(&str, &str); 4] = [
    ("Default", include_str!("../templates/Default.mdtemplate/template.toml")),
    ("Academic", include_str!("../templates/Academic.mdtemplate/template.toml")),
    ("Typewriter", include_str!("../templates/Typewriter.mdtemplate/template.toml")),
    ("Letter", include_str!("../templates/Letter.mdtemplate/template.toml")),
];

fn builtin(name: &str) -> Template {
    let src = BUILTINS.iter().find(|b| b.0 == name).unwrap().1;
    Template::parse(src).unwrap_or_else(|e| panic!("{name}: {e}"))
}

#[test]
fn builtins_parse_and_round_trip() {
    for (name, src) in BUILTINS {
        let t = Template::parse(src).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(t.meta.name, name);
        assert_eq!(t.meta.author, "Markdown");
        assert_eq!(t.meta.version, "1");
        assert!(!t.meta.description.is_empty());
        assert_eq!(Template::parse(&t.to_toml()).unwrap(), t, "{name}");
    }
}

#[test]
fn the_default_template_is_the_preview_as_it_is() {
    assert_eq!(builtin("Default").spec, TemplateSpec::default());
    assert_eq!(css(&builtin("Default").spec), preview_css(&theme(), &Typography::default()));
}

#[test]
fn academic_numbers_justifies_and_rules_tables() {
    let out = added(&builtin("Academic").spec);
    for want in ["h1::before { content: counter(md-h1) \". \"; }", "h2::before", "h3::before", "text-align: justify", ".footnotes { font-size: 0.8em; }", "table { border-top: 2px solid var(--text); }", "th { "] {
        assert!(out.contains(want), "{want}\n{out}");
    }
    assert!(out.contains("body { font-family: Charter, Iowan Old Style, Georgia, serif;"));
}

#[test]
fn typewriter_is_mono_throughout_with_dashed_rules_and_square_corners() {
    let out = added(&builtin("Typewriter").spec);
    let t = Typography::default();
    assert!(out.contains(&format!("body {{ font-family: {};", t.mono_family)), "{out}");
    assert!(out.contains("line-height: 1.6"));
    assert!(out.contains("hr { border-top: 1px dashed var(--rule); }"));
    for sel in ["pre", ":not(pre) > code", "img"] {
        assert!(out.contains(&format!("{sel} {{ border-radius: 0px; }}")), "{sel}");
    }
    for h in ["h1", "h2", "h3", "h4", "h5", "h6"] {
        assert!(out.contains(&format!("{h} {{ font-family: {}", t.mono_family)), "{h}");
    }
}

#[test]
fn letter_makes_h1_a_title_block_in_a_wide_column() {
    let out = added(&builtin("Letter").spec);
    for want in ["max-width: 64ch", "padding-left: 72px", "h1 { font-size: 2.4em;", "margin-bottom: 1.2em", "h2 { font-size: 1.25em;", "h3 { font-size: 1.05em;", "sans-serif"] {
        assert!(out.contains(want), "{want}\n{out}");
    }
}

// ----- properties ---------------------------------------------------------------------------------------------------

fn length() -> impl Strategy<Value = Length> {
    (-1000.0f64..1000.0, prop_oneof![Just(Unit::Em), Just(Unit::Px), Just(Unit::Pt)]).prop_map(|(v, u)| Length::new(v, u))
}

fn colour() -> impl Strategy<Value = ColorRef> {
    prop_oneof![
        (0..ThemeColor::ALL.len()).prop_map(|i| ColorRef::Theme(ThemeColor::ALL[i])),
        (any::<u8>(), any::<u8>(), any::<u8>()).prop_map(|(r, g, b)| ColorRef::Fixed(Rgb(r, g, b))),
    ]
}

fn family() -> impl Strategy<Value = FontFamily> {
    prop_oneof![
        Just(FontFamily::Body),
        Just(FontFamily::Mono),
        // Any text but the two words that mean the editor's faces; blank would not be a name.
        "\\PC{1,12}".prop_filter("a name", |s| {
            let t = s.trim().to_ascii_lowercase();
            !t.is_empty() && t != "body" && t != "mono"
        })
        .prop_map(|s| FontFamily::Named(s.trim().to_owned())),
    ]
}

fn pick<T: Copy + std::fmt::Debug + 'static>(all: &'static [T]) -> impl Strategy<Value = T> {
    (0..all.len()).prop_map(move |i| all[i])
}

fn border() -> impl Strategy<Value = Border> {
    (pick(Side::ALL), pick(BorderStyle::ALL), length(), colour()).prop_map(|(side, style, width, color)| Border { side, style, width, color })
}

fn element_style() -> impl Strategy<Value = ElementStyle> {
    let a = (
        proptest::option::of(family()),
        proptest::option::of(length()),
        proptest::option::of(100u16..=900),
        proptest::option::of(any::<bool>()),
        proptest::option::of(colour()),
        proptest::option::of(colour()),
        proptest::option::of(length()),
        proptest::option::of(length()),
        proptest::option::of(-10.0f64..10.0),
    );
    let b = (
        proptest::option::of(pick(Align::ALL)),
        proptest::option::of(length()),
        proptest::option::of(length()),
        proptest::option::of(pick(Transform::ALL)),
        proptest::option::of(pick(Decoration::ALL)),
        proptest::option::of(border()),
        proptest::option::of(length()),
        proptest::option::of(any::<bool>()),
        proptest::option::of(pick(Marker::ALL)),
    );
    (a, b).prop_map(|(a, b)| ElementStyle {
        font_family: a.0,
        font_size: a.1,
        weight: a.2,
        italic: a.3,
        color: a.4,
        background: a.5,
        space_above: a.6,
        space_below: a.7,
        line_height: a.8,
        align: b.0,
        indent: b.1,
        letter_spacing: b.2,
        transform: b.3,
        decoration: b.4,
        border: b.5,
        radius: b.6,
        numbered: b.7,
        marker: b.8,
    })
}

fn template() -> impl Strategy<Value = Template> {
    let page = (
        proptest::option::of(0.0f64..500.0),
        proptest::option::of(length()),
        proptest::option::of(colour()),
        proptest::option::of(pick(Align::ALL)),
    )
        .prop_map(|(measure_ch, side_padding, background, align)| PageStyle { measure_ch, side_padding, background, align });
    let elements = proptest::collection::btree_map(pick_kind(), element_style(), 0..8);
    let meta = ("\\PC{0,10}", "\\PC{0,10}", "\\PC{0,4}", "\\PC{0,30}")
        .prop_map(|(name, author, version, description)| TemplateMeta { name, author, version, description });
    (meta, page, elements).prop_map(|(meta, page, mut elements)| {
        // An element with nothing set is not written, so it is not kept either.
        elements.retain(|_, s| !s.is_empty());
        Template { meta, spec: TemplateSpec { page, elements } }
    })
}

fn pick_kind() -> impl Strategy<Value = ElementKind> {
    let all = ElementKind::all();
    (0..all.len()).prop_map(move |i| all[i])
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn any_template_round_trips_through_toml(t in template()) {
        let text = t.to_toml();
        let back = Template::parse(&text).unwrap();
        prop_assert_eq!(&back, &t);
        prop_assert_eq!(back.to_toml(), text);
    }

    #[test]
    fn template_css_never_panics_and_keeps_the_base_and_print_block(t in template(), size in 1.0f64..64.0) {
        let typography = Typography { font_size_px: size, ..Typography::default() };
        let theme = theme();
        let out = template_css(&t.spec, &theme, &typography);
        let base = template_css(&TemplateSpec::default(), &theme, &typography);
        let head = base.find("@page {").unwrap();
        prop_assert!(out.starts_with(&base[..head]));
        prop_assert!(out.ends_with(&base[head..]));
        // Braces stay balanced whatever the names.
        let mid = &out[head..out.len() - (base.len() - head)];
        prop_assert_eq!(mid.matches('{').count(), mid.matches('}').count());
    }

    #[test]
    fn parse_never_panics_on_any_text(s in "\\PC{0,200}") {
        let _ = Template::parse(&s);
    }
}
