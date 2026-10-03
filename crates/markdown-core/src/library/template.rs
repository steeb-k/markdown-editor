//! Note templates: `{{date}}`, `{{time}}`, `{{title}}`, `{{today}}` (whatever the shell
//! supplies) and `{{cursor}}`.

use std::collections::HashMap;

use crate::types::OffsetEncoding;

/// A template with its placeholders filled in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Template {
    pub text: String,
    /// Where the caret goes: where `{{cursor}}` stood, else the end of the text. In the unit
    /// of the encoding it was asked for.
    pub cursor: u32,
}

/// Fills `{{name}}` placeholders from `vars` (names are compared case-insensitively, blanks
/// inside the braces are ignored). A placeholder `vars` does not know stays as written. The
/// first `{{cursor}}` marks the caret; every `{{cursor}}` is removed.
pub fn expand_template(text: &str, vars: &HashMap<String, String>, encoding: OffsetEncoding) -> Template {
    let lowered: HashMap<String, &String> = vars.iter().map(|(k, v)| (k.trim().to_lowercase(), v)).collect();
    let mut out = String::with_capacity(text.len());
    let mut cursor: Option<usize> = None;
    let mut rest = text;
    while let Some(open) = rest.find("{{") {
        out.push_str(&rest[..open]);
        let after = &rest[open + 2..];
        match after.find("}}") {
            Some(close) if !after[..close].contains(['\n', '\r', '{']) => {
                let name = after[..close].trim().to_lowercase();
                if name == "cursor" {
                    cursor.get_or_insert(out.len());
                } else if let Some(v) = lowered.get(&name) {
                    out.push_str(v);
                } else {
                    out.push_str(&rest[open..open + 2 + close + 2]);
                }
                rest = &after[close + 2..];
            }
            _ => {
                out.push_str("{{");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    let at = cursor.unwrap_or(out.len());
    let cursor = match encoding {
        OffsetEncoding::Utf8 => at,
        OffsetEncoding::Utf16 => out[..at].encode_utf16().count(),
        OffsetEncoding::Utf32 => out[..at].chars().count(),
    };
    Template { text: out, cursor: cursor.min(u32::MAX as usize) as u32 }
}
