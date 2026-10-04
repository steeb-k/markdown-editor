//! A snapshot history for documents, kept in a folder the shell provides.
//!
//! This is the one place the core touches the file system: it owns `dir` and nothing else. Layout,
//! chosen so a person can recover a text without the app:
//!
//! ```text
//! <dir>/<slug>-<hash8>/index.json     the versions of one document key, newest last
//! <dir>/<slug>-<hash8>/<sha256>.md    one file per distinct text, named by the SHA-256 of its bytes
//! ```
//!
//! Every write is a temp file and a rename, so an interrupted write leaves the old file whole. An
//! index that cannot be read (damaged by hand or by the disk) is rebuilt from the text files. All
//! calls take `&self`, serialise on one lock and are cheap: they work on the index of one key and on
//! the text files they name. The diff is `diff_lines`, a line-based Myers diff in this crate.
//!
//! Time is in whole seconds since the Unix epoch. `record_at` and `prune_at` take it explicitly (the
//! tests drive a synthetic clock); `record` and `prune` read the system clock.

mod diff;
mod json;

pub use diff::{diff_lines, line_counts, DiffHunk, DiffKind};

use json::Json;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub type VersionId = u64;

const HOUR: i64 = 3600;
const DAY: i64 = 24 * HOUR;
const WEEK: i64 = 7 * DAY;
/// Per key: the texts kept, once each, add up to at most this many bytes.
pub const DEFAULT_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Why a snapshot was taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// A pause in typing.
    Pause,
    /// The document left the window, or the app quit.
    Close,
    /// An explicit save.
    Save,
    /// The state just before a restore, or the restore itself.
    Restore,
    /// A draft was created from an untitled document.
    Draft,
    /// Found on disk when the index had to be rebuilt.
    Recovered,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Pause => "pause",
            Reason::Close => "close",
            Reason::Save => "save",
            Reason::Restore => "restore",
            Reason::Draft => "draft",
            Reason::Recovered => "recovered",
        }
    }
    fn parse(s: &str) -> Reason {
        match s {
            "pause" => Reason::Pause,
            "close" => Reason::Close,
            "save" => Reason::Save,
            "restore" => Reason::Restore,
            "draft" => Reason::Draft,
            _ => Reason::Recovered,
        }
    }
}

/// One snapshot. `added` and `removed` are the lines changed since the snapshot before it (all
/// lines are added for the first one).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    pub id: VersionId,
    pub time: i64,
    pub reason: Reason,
    pub message: Option<String>,
    pub bytes: u64,
    pub added: u32,
    pub removed: u32,
}

#[derive(Debug, Clone)]
struct Entry {
    v: Version,
    sha: String,
}

#[derive(Debug, Clone)]
struct Index {
    key: String,
    next_id: VersionId,
    entries: Vec<Entry>,
}

pub struct History {
    dir: PathBuf,
    max_bytes: Mutex<u64>,
    lock: Mutex<()>,
    /// The store folder itself, held (`flock`) for each call, so two stores on one folder (two processes, or two `History`
    /// values in one) take turns instead of losing each other's index updates. None when it cannot be opened: the
    /// in-process lock still holds.
    file_lock: Option<fs::File>,
}

/// One call's hold on the store: the in-process lock, then the folder's file lock.
struct Guard<'a> {
    _g: std::sync::MutexGuard<'a, ()>,
    file: Option<&'a fs::File>,
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        if let Some(f) = self.file {
            let _ = f.unlock();
        }
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn sha_of(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

/// Writes `data` to `path` through a temp file in the same folder. The temp file's name is this write's own (process
/// and a counter), so two stores on one folder never write into each other's temp file or rename it away.
fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_file_name(format!(".{name}.{}.{seq}.tmp", std::process::id()));
    let mut f = fs::File::create(&tmp)?;
    f.write_all(data)?;
    f.sync_all()?;
    drop(f);
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
}

impl History {
    /// Opens (and creates, with its parents) the store folder.
    pub fn open(dir: impl Into<PathBuf>) -> std::io::Result<History> {
        let dir = dir.into();
        fs::create_dir_all(&dir)?;
        let file_lock = fs::File::open(&dir).ok();
        Ok(History { dir, max_bytes: Mutex::new(DEFAULT_MAX_BYTES), lock: Mutex::new(()), file_lock })
    }

    fn guard(&self) -> Guard<'_> {
        let g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let file = self.file_lock.as_ref().filter(|f| f.lock().is_ok());
        Guard { _g: g, file }
    }

    /// Changes the per-key size cap (the default is 10 MB). For tests and for the shell's tuning.
    pub fn set_max_bytes(&self, max: u64) {
        *self.max_bytes.lock().unwrap() = max;
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Records `text` for `key` unless it equals the latest snapshot. `None` also when the store
    /// cannot be written.
    pub fn record(&self, key: &str, text: &str, reason: Reason, message: Option<&str>) -> Option<VersionId> {
        self.record_at(key, text, reason, message, now_secs())
    }

    pub fn record_at(&self, key: &str, text: &str, reason: Reason, message: Option<&str>, now: i64) -> Option<VersionId> {
        let _g = self.guard();
        let mut idx = self.load(key);
        let sha = sha_of(text);
        let kdir = self.key_dir(key);
        let file = kdir.join(format!("{sha}.md"));
        if idx.entries.last().is_some_and(|e| e.sha == sha) {
            // The latest already is this text; only its file is put back if something took it away.
            if !file.exists() && fs::create_dir_all(&kdir).is_ok() {
                let _ = write_atomic(&file, text.as_bytes());
            }
            return None;
        }
        let prev = idx.entries.last().and_then(|e| self.read_text(key, &e.sha)).unwrap_or_default();
        let (added, removed) = line_counts(&prev, text);
        fs::create_dir_all(&kdir).ok()?;
        if !file.exists() {
            write_atomic(&file, text.as_bytes()).ok()?;
        }
        let id = idx.next_id;
        idx.next_id = idx.next_id.saturating_add(1);
        let message = message.filter(|m| !m.is_empty()).map(str::to_string);
        idx.entries.push(Entry { v: Version { id, time: now, reason, message, bytes: text.len() as u64, added, removed }, sha });
        let before = referenced(&idx);
        retain(&mut idx, now, *self.max_bytes.lock().unwrap());
        self.save(&idx).ok()?;
        self.sweep(key, &before, &idx);
        Some(id)
    }

    /// The versions of `key`, newest first.
    pub fn versions(&self, key: &str) -> Vec<Version> {
        let _g = self.guard();
        self.load(key).entries.into_iter().rev().map(|e| e.v).collect()
    }

    /// The text of one version; `None` when the version or its file is gone.
    pub fn text(&self, key: &str, id: VersionId) -> Option<String> {
        let _g = self.guard();
        let idx = self.load(key);
        let e = idx.entries.iter().find(|e| e.v.id == id)?;
        self.read_text(key, &e.sha)
    }

    /// The line diff from version `id` to `current`.
    pub fn diff(&self, key: &str, id: VersionId, current: &str) -> Option<Vec<DiffHunk>> {
        let old = self.text(key, id)?;
        Some(diff_lines(&old, current))
    }

    /// Moves the history of `old` to `new` (a rename or a move). When `new` already has a history
    /// the two are merged by time. `false` when `old` has none or the store cannot be written.
    pub fn rekey(&self, old: &str, new: &str) -> bool {
        if old == new {
            return false;
        }
        let _g = self.guard();
        let (from, to) = (self.key_dir(old), self.key_dir(new));
        if !from.exists() {
            return false;
        }
        let src = self.load(old);
        if !to.exists() {
            if fs::rename(&from, &to).is_err() {
                return false;
            }
            let mut idx = src;
            idx.key = new.to_string();
            return self.save(&idx).is_ok();
        }
        let dst = self.load(new);
        let mut all: Vec<Entry> = src.entries.into_iter().chain(dst.entries).collect();
        all.sort_by_key(|e| (e.v.time, e.v.id));
        let mut merged = Index { key: new.to_string(), next_id: 1, entries: Vec::new() };
        for mut e in all {
            let from_file = from.join(format!("{}.md", e.sha));
            let to_file = to.join(format!("{}.md", e.sha));
            if !to_file.exists() && from_file.exists() && fs::copy(&from_file, &to_file).is_err() {
                continue;
            }
            e.v.id = merged.next_id;
            merged.next_id += 1;
            merged.entries.push(e);
        }
        if self.save(&merged).is_err() {
            return false;
        }
        let _ = fs::remove_dir_all(&from);
        true
    }

    /// Every key that has a history (read from the indexes; for moving a folder's notes, which are keys that share a prefix).
    pub fn keys(&self) -> Vec<String> {
        let _g = self.guard();
        let Ok(rd) = fs::read_dir(&self.dir) else { return Vec::new() };
        let mut keys: Vec<String> = rd
            .flatten()
            .filter_map(|e| {
                let text = fs::read_to_string(e.path().join("index.json")).ok()?;
                json::parse(&text)?.get("key")?.as_str().map(str::to_string)
            })
            .collect();
        keys.sort();
        keys
    }

    /// Deletes the whole history of `key`.
    pub fn forget(&self, key: &str) {
        let _g = self.guard();
        let _ = fs::remove_dir_all(self.key_dir(key));
    }

    /// Applies the retention rule now; returns how many versions it dropped.
    pub fn prune(&self, key: &str) -> usize {
        self.prune_at(key, now_secs())
    }

    pub fn prune_at(&self, key: &str, now: i64) -> usize {
        let _g = self.guard();
        if !self.key_dir(key).exists() {
            return 0;
        }
        let mut idx = self.load(key);
        let (n, before) = (idx.entries.len(), referenced(&idx));
        retain(&mut idx, now, *self.max_bytes.lock().unwrap());
        let dropped = n - idx.entries.len();
        if dropped > 0 && self.save(&idx).is_ok() {
            self.sweep(key, &before, &idx);
        }
        dropped
    }

    // ----- files -------------------------------------------------------------------------

    fn key_dir(&self, key: &str) -> PathBuf {
        let slug: String = key.chars().map(|c| if c.is_alphanumeric() { c } else { '_' }).take(40).collect();
        self.dir.join(format!("{slug}-{}", &sha_of(key)[..8]))
    }

    fn read_text(&self, key: &str, sha: &str) -> Option<String> {
        String::from_utf8(fs::read(self.key_dir(key).join(format!("{sha}.md"))).ok()?).ok()
    }

    fn save(&self, idx: &Index) -> std::io::Result<()> {
        let kdir = self.key_dir(&idx.key);
        fs::create_dir_all(&kdir)?;
        let entries = idx
            .entries
            .iter()
            .map(|e| {
                Json::Obj(vec![
                    ("id".into(), Json::Int(e.v.id as i64)),
                    ("time".into(), Json::Int(e.v.time)),
                    ("reason".into(), Json::Str(e.v.reason.as_str().into())),
                    ("message".into(), e.v.message.clone().map_or(Json::Null, Json::Str)),
                    ("sha".into(), Json::Str(e.sha.clone())),
                    ("bytes".into(), Json::Int(e.v.bytes as i64)),
                    ("added".into(), Json::Int(e.v.added as i64)),
                    ("removed".into(), Json::Int(e.v.removed as i64)),
                ])
            })
            .collect();
        let doc = Json::Obj(vec![
            ("version".into(), Json::Int(1)),
            ("key".into(), Json::Str(idx.key.clone())),
            ("next_id".into(), Json::Int(idx.next_id as i64)),
            ("entries".into(), Json::Arr(entries)),
        ]);
        let mut out = String::new();
        doc.write(&mut out, 0);
        out.push('\n');
        write_atomic(&kdir.join("index.json"), out.as_bytes())
    }

    /// Deletes text files that were referenced before and no longer are.
    fn sweep(&self, key: &str, before: &HashSet<String>, idx: &Index) {
        let now = referenced(idx);
        for sha in before.difference(&now) {
            let _ = fs::remove_file(self.key_dir(key).join(format!("{sha}.md")));
        }
    }

    fn load(&self, key: &str) -> Index {
        let kdir = self.key_dir(key);
        let empty = Index { key: key.to_string(), next_id: 1, entries: Vec::new() };
        if !kdir.exists() {
            return empty;
        }
        match fs::read_to_string(kdir.join("index.json")).ok().and_then(|s| parse_index(&s)) {
            Some(mut idx) if idx.key == key => {
                idx.next_id = idx.next_id.max(idx.entries.iter().map(|e| e.v.id.saturating_add(1)).max().unwrap_or(1));
                idx
            }
            _ => self.recover(key, &kdir, empty),
        }
    }

    /// Rebuilds the index from the text files: oldest file first, times from the files' dates.
    fn recover(&self, key: &str, kdir: &Path, mut idx: Index) -> Index {
        let mut files: Vec<(std::time::SystemTime, String)> = Vec::new();
        if let Ok(rd) = fs::read_dir(kdir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let Some(stem) = name.strip_suffix(".md") else { continue };
                if stem.len() != 64 || !stem.bytes().all(|b| b.is_ascii_hexdigit()) {
                    continue;
                }
                let t = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
                files.push((t, stem.to_string()));
            }
        }
        files.sort();
        let mut prev = String::new();
        for (t, sha) in files {
            let Some(text) = self.read_text(key, &sha) else { continue };
            let (added, removed) = line_counts(&prev, &text);
            let time = t.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
            let id = idx.next_id;
            idx.next_id += 1;
            idx.entries.push(Entry {
                v: Version { id, time, reason: Reason::Recovered, message: None, bytes: text.len() as u64, added, removed },
                sha,
            });
            prev = text;
        }
        let _ = self.save(&idx);
        idx
    }
}

fn parse_index(s: &str) -> Option<Index> {
    let j = json::parse(s)?;
    let key = j.get("key")?.as_str()?.to_string();
    let next_id = j.get("next_id")?.as_i64()?.max(1) as u64;
    let mut entries: Vec<Entry> = Vec::new();
    let mut ids = HashSet::new();
    for e in j.get("entries")?.as_arr()? {
        let sha = e.get("sha")?.as_str()?.to_string();
        if sha.len() != 64 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        // An id below zero, or one used twice, is damage: the index is rebuilt from the text files.
        let id = u64::try_from(e.get("id")?.as_i64()?).ok()?;
        if !ids.insert(id) {
            return None;
        }
        entries.push(Entry {
            v: Version {
                id,
                time: e.get("time")?.as_i64()?,
                reason: Reason::parse(e.get("reason")?.as_str()?),
                message: e.get("message").and_then(|m| m.as_str()).map(str::to_string),
                bytes: e.get("bytes")?.as_i64()?.max(0) as u64,
                added: e.get("added")?.as_i64()?.max(0) as u32,
                removed: e.get("removed")?.as_i64()?.max(0) as u32,
            },
            sha,
        });
    }
    Some(Index { key, next_id, entries })
}

fn referenced(idx: &Index) -> HashSet<String> {
    idx.entries.iter().map(|e| e.sha.clone()).collect()
}

/// The retention rule. The newest snapshot and every snapshot with a message always stay. Of the
/// rest: all of those under 24 hours old, then the newest of each clock hour up to a week old, then
/// the newest of each day. Then, while the distinct texts kept exceed `max_bytes`, the oldest
/// snapshot without a message goes.
fn retain(idx: &mut Index, now: i64, max_bytes: u64) {
    let n = idx.entries.len();
    let mut keep = vec![true; n];
    let mut seen: HashSet<(u8, i64)> = HashSet::new();
    for i in (0..n).rev() {
        let v = &idx.entries[i].v;
        let age = now.saturating_sub(v.time).max(0);
        let bucket = if age < DAY {
            None
        } else if age < WEEK {
            Some((0, v.time.div_euclid(HOUR)))
        } else {
            Some((1, v.time.div_euclid(DAY)))
        };
        if let Some(b) = bucket {
            let fresh = seen.insert(b);
            if !fresh && i != n - 1 && v.message.is_none() {
                keep[i] = false;
            }
        }
    }
    // Size cap over distinct texts.
    let mut uses: HashMap<&str, (usize, u64)> = HashMap::new();
    for (i, e) in idx.entries.iter().enumerate() {
        if keep[i] {
            let u = uses.entry(&e.sha).or_insert((0, e.v.bytes));
            u.0 += 1;
        }
    }
    let mut total: u64 = uses.values().map(|u| u.1).sum();
    #[allow(clippy::needless_range_loop)]
    for i in 0..n {
        if total <= max_bytes {
            break;
        }
        if keep[i] && i != n - 1 && idx.entries[i].v.message.is_none() {
            keep[i] = false;
            let u = uses.get_mut(idx.entries[i].sha.as_str()).unwrap();
            u.0 -= 1;
            if u.0 == 0 {
                total -= u.1;
            }
        }
    }
    let mut k = keep.into_iter();
    idx.entries.retain(|_| k.next().unwrap());
}
