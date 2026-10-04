//! UniFFI surface of `markdown_core::history`. Mirrors records and forwards calls; no logic beyond
//! turning the diff's byte ranges into UTF-16 ranges for the shell. Text crosses as UTF-8 strings.

use markdown_core::history as ch;

use crate::Utf16Range;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum HistoryError {
    /// The store folder could not be created or opened.
    Io { message: String },
}

impl std::fmt::Display for HistoryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let HistoryError::Io { message } = self;
        write!(f, "history store: {message}")
    }
}

impl std::error::Error for HistoryError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryReason {
    Pause,
    Close,
    Save,
    Restore,
    Draft,
    Recovered,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryDiffKind {
    Equal,
    Added,
    Removed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryVersion {
    pub id: u64,
    /// Seconds since the Unix epoch.
    pub time: i64,
    pub reason: HistoryReason,
    pub message: Option<String>,
    pub bytes: u64,
    pub added: u32,
    pub removed: u32,
}

/// `old_range` is in the version's text, `new_range` in the current text; both in UTF-16 units.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryHunk {
    pub kind: HistoryDiffKind,
    pub old_range: Utf16Range,
    pub new_range: Utf16Range,
    pub text: String,
}

impl From<HistoryReason> for ch::Reason {
    fn from(r: HistoryReason) -> Self {
        match r {
            HistoryReason::Pause => ch::Reason::Pause,
            HistoryReason::Close => ch::Reason::Close,
            HistoryReason::Save => ch::Reason::Save,
            HistoryReason::Restore => ch::Reason::Restore,
            HistoryReason::Draft => ch::Reason::Draft,
            HistoryReason::Recovered => ch::Reason::Recovered,
        }
    }
}
impl From<ch::Reason> for HistoryReason {
    fn from(r: ch::Reason) -> Self {
        match r {
            ch::Reason::Pause => HistoryReason::Pause,
            ch::Reason::Close => HistoryReason::Close,
            ch::Reason::Save => HistoryReason::Save,
            ch::Reason::Restore => HistoryReason::Restore,
            ch::Reason::Draft => HistoryReason::Draft,
            ch::Reason::Recovered => HistoryReason::Recovered,
        }
    }
}
impl From<ch::Version> for HistoryVersion {
    fn from(v: ch::Version) -> Self {
        HistoryVersion {
            id: v.id,
            time: v.time,
            reason: v.reason.into(),
            message: v.message,
            bytes: v.bytes,
            added: v.added,
            removed: v.removed,
        }
    }
}

/// Converts increasing byte offsets of `s` to UTF-16 offsets in one pass.
struct Utf16Walker<'a> {
    s: &'a str,
    byte: usize,
    units: u32,
}

impl<'a> Utf16Walker<'a> {
    fn new(s: &'a str) -> Self {
        Self { s, byte: 0, units: 0 }
    }
    fn at(&mut self, byte: usize) -> u32 {
        if byte < self.byte {
            self.byte = 0;
            self.units = 0;
        }
        self.units += self.s[self.byte..byte].encode_utf16().count() as u32;
        self.byte = byte;
        self.units
    }
}

fn hunks_utf16(old: &str, new: &str) -> Vec<HistoryHunk> {
    let (mut wo, mut wn) = (Utf16Walker::new(old), Utf16Walker::new(new));
    ch::diff_lines(old, new)
        .into_iter()
        .map(|h| HistoryHunk {
            kind: match h.kind {
                ch::DiffKind::Equal => HistoryDiffKind::Equal,
                ch::DiffKind::Added => HistoryDiffKind::Added,
                ch::DiffKind::Removed => HistoryDiffKind::Removed,
            },
            old_range: Utf16Range { start: wo.at(h.old_range.start), end: wo.at(h.old_range.end) },
            new_range: Utf16Range { start: wn.at(h.new_range.start), end: wn.at(h.new_range.end) },
            text: h.text,
        })
        .collect()
}

/// The snapshot store. Every call is safe from any thread.
#[derive(uniffi::Object)]
pub struct HistoryStore {
    inner: ch::History,
}

#[uniffi::export]
impl HistoryStore {
    #[uniffi::constructor]
    pub fn open(dir: String) -> Result<Self, HistoryError> {
        ch::History::open(dir)
            .map(|inner| Self { inner })
            .map_err(|e| HistoryError::Io { message: e.to_string() })
    }

    pub fn set_max_bytes(&self, max: u64) {
        self.inner.set_max_bytes(max)
    }

    pub fn record(&self, key: String, text: String, reason: HistoryReason, message: Option<String>) -> Option<u64> {
        self.inner.record(&key, &text, reason.into(), message.as_deref())
    }

    pub fn record_at(&self, key: String, text: String, reason: HistoryReason, message: Option<String>, now: i64) -> Option<u64> {
        self.inner.record_at(&key, &text, reason.into(), message.as_deref(), now)
    }

    pub fn versions(&self, key: String) -> Vec<HistoryVersion> {
        self.inner.versions(&key).into_iter().map(Into::into).collect()
    }

    pub fn text(&self, key: String, id: u64) -> Option<String> {
        self.inner.text(&key, id)
    }

    pub fn diff(&self, key: String, id: u64, current: String) -> Option<Vec<HistoryHunk>> {
        let old = self.inner.text(&key, id)?;
        Some(hunks_utf16(&old, &current))
    }

    pub fn rekey(&self, old: String, new: String) -> bool {
        self.inner.rekey(&old, &new)
    }

    pub fn keys(&self) -> Vec<String> {
        self.inner.keys()
    }

    pub fn forget(&self, key: String) {
        self.inner.forget(&key)
    }

    pub fn prune(&self, key: String) -> u64 {
        self.inner.prune(&key) as u64
    }

    pub fn prune_at(&self, key: String, now: i64) -> u64 {
        self.inner.prune_at(&key, now) as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunk_ranges_are_utf16() {
        let old = "\u{1F600}\nb\n";
        let new = "\u{1F600}\nB\n";
        let h = hunks_utf16(old, new);
        assert_eq!(h.len(), 3);
        assert_eq!(h[0].old_range, Utf16Range { start: 0, end: 3 });
        assert_eq!(h[1].kind, HistoryDiffKind::Removed);
        assert_eq!(h[1].old_range, Utf16Range { start: 3, end: 5 });
        assert_eq!(h[2].new_range, Utf16Range { start: 3, end: 5 });
    }
}
