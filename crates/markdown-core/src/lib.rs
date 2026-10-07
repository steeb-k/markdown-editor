//! Platform-neutral Markdown core. No UI or platform dependencies.

mod analysis;
pub mod authorship;
pub mod autolink;
mod code;
mod conceal;
mod dirty;
mod document;
mod edit;
mod focus;
mod front_matter;
pub mod highlight;
pub mod history;
pub mod library;
mod lines;
mod offsets;
mod outline;
mod pos;
mod preview_css;
mod render;
mod sanitize;
pub mod template;
pub mod theme;
mod types;
pub mod wiki;

pub use document::Document;
pub use highlight::{common_language_count, languages};
pub use preview_css::{preview_css, PreviewStyle, Typography};
pub use render::{slug, ImageSize, RenderOptions};
pub use theme::{builtin_themes, contrast_ratio, syntax_palette, theme_by_id, Color, Colors, SyntaxPalette, Theme};
pub use types::*;

/// Version of the core crate.
pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_is_set() {
        assert!(!super::core_version().is_empty());
    }
}
