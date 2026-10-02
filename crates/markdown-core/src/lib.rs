//! Platform-neutral Markdown core. No UI or platform dependencies.

mod analysis;
pub mod autolink;
mod conceal;
mod dirty;
mod document;
mod edit;
mod lines;
mod offsets;
pub mod theme;
mod types;

pub use document::Document;
pub use theme::{builtin_themes, contrast_ratio, theme_by_id, Color, Colors, Theme};
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
