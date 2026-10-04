//! The snapshot history: recording, deduplication, listing, diff, rekey, forget, retention with a
//! synthetic clock, recovery of a damaged index, and a property test of the diff.
use markdown_core::history::*;
use proptest::prelude::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

static N: AtomicUsize = AtomicUsize::new(0);

fn store() -> (History, PathBuf) {
    let dir = std::env::temp_dir().join(format!("md-history-test-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&dir);
    (History::open(&dir).unwrap(), dir)
}

fn apply(hunks: &[DiffHunk], side_old: bool) -> String {
    hunks
        .iter()
        .filter(|h| h.kind == DiffKind::Equal || h.kind == if side_old { DiffKind::Removed } else { DiffKind::Added })
        .map(|h| h.text.as_str())
        .collect()
}

#[test]
fn record_dedupes_and_lists_newest_first() {
    let (h, dir) = store();
    let a = h.record_at("k", "one\n", Reason::Pause, None, 100).unwrap();
    assert_eq!(h.record_at("k", "one\n", Reason::Close, None, 101), None);
    let b = h.record_at("k", "one\ntwo\n", Reason::Save, Some("milestone"), 102).unwrap();
    assert!(b > a);
    // Going back to an earlier text is a new version, not a duplicate of the old one.
    let c = h.record_at("k", "one\n", Reason::Restore, None, 103).unwrap();
    let v = h.versions("k");
    assert_eq!(v.iter().map(|v| v.id).collect::<Vec<_>>(), vec![c, b, a]);
    assert_eq!((v[2].added, v[2].removed, v[2].bytes), (1, 0, 4));
    assert_eq!((v[1].added, v[1].removed), (1, 0));
    assert_eq!((v[0].added, v[0].removed), (0, 1));
    assert_eq!(v[1].message.as_deref(), Some("milestone"));
    assert_eq!(v[1].reason, Reason::Save);
    assert_eq!(h.text("k", a).unwrap(), "one\n");
    assert_eq!(h.text("k", b).unwrap(), "one\ntwo\n");
    assert_eq!(h.text("k", 999), None);
    assert!(h.versions("other").is_empty());
    // Two distinct texts, so two text files and an index.
    let key_dir = std::fs::read_dir(&dir).unwrap().next().unwrap().unwrap().path();
    let names: Vec<String> = std::fs::read_dir(&key_dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(names.iter().filter(|n| n.ends_with(".md")).count(), 2, "{names:?}");
    assert!(names.contains(&"index.json".to_string()));
}

#[test]
fn survives_reopen_and_odd_keys() {
    let (h, dir) = store();
    let key = "notes/Ünï cödé \"quoted\" / ../x.md";
    h.record_at(key, "a\n", Reason::Draft, Some("emoji \u{1F600} \"q\" \\ \n tab\t"), 5).unwrap();
    drop(h);
    let h = History::open(&dir).unwrap();
    let v = h.versions(key);
    assert_eq!(v.len(), 1);
    assert_eq!(v[0].message.as_deref(), Some("emoji \u{1F600} \"q\" \\ \n tab\t"));
    assert_eq!(v[0].reason, Reason::Draft);
    // Nothing escaped the store folder.
    assert!(!dir.parent().unwrap().join("x.md").exists());
}

#[test]
fn unicode_and_crlf_texts_round_trip() {
    let (h, _) = store();
    let t1 = "caf\u{e9}\r\n\u{65E5}\u{672C}\u{8A9E}\r\n";
    let t2 = "caf\u{e9}\n\u{65E5}\u{672C}\u{8A9E}\r\nnew \u{1F600}";
    let a = h.record_at("u", t1, Reason::Pause, None, 1).unwrap();
    let b = h.record_at("u", t2, Reason::Pause, None, 2).unwrap();
    assert_eq!(h.text("u", a).unwrap(), t1);
    assert_eq!(h.text("u", b).unwrap(), t2);
    // The CRLF line and the LF line differ; the unchanged Japanese line is equal.
    let d = h.diff("u", a, t2).unwrap();
    assert_eq!(apply(&d, true), t1);
    assert_eq!(apply(&d, false), t2);
    assert!(d.iter().any(|x| x.kind == DiffKind::Equal && x.text.starts_with('\u{65E5}')));
    let v = h.versions("u");
    assert_eq!((v[0].added, v[0].removed), (2, 1));
}

#[test]
fn diff_hunks_and_ranges() {
    let (h, _) = store();
    let old = "a\nb\nc\nd\n";
    let id = h.record_at("d", old, Reason::Pause, None, 1).unwrap();
    let cur = "a\nB\nc\nd\ne";
    let hunks = h.diff("d", id, cur).unwrap();
    let kinds: Vec<_> = hunks.iter().map(|x| x.kind).collect();
    assert_eq!(kinds, vec![DiffKind::Equal, DiffKind::Removed, DiffKind::Added, DiffKind::Equal, DiffKind::Added]);
    assert_eq!(hunks[1].text, "b\n");
    assert_eq!(hunks[1].old_range, 2..4);
    assert!(hunks[1].new_range.is_empty());
    assert_eq!(hunks[2].text, "B\n");
    assert_eq!(&cur[hunks[2].new_range.clone()], "B\n");
    assert_eq!(hunks[4].text, "e");
    assert_eq!(h.diff("d", 77, cur), None);
    assert!(diff_lines("", "").is_empty());
    let whole = diff_lines("", "x\ny\n");
    assert_eq!(whole.len(), 1);
    assert_eq!(whole[0].kind, DiffKind::Added);
    assert_eq!(diff_lines("x\n", "").first().unwrap().kind, DiffKind::Removed);
}

#[test]
fn rekey_moves_and_merges() {
    let (h, _) = store();
    h.record_at("old", "one\n", Reason::Pause, None, 1).unwrap();
    h.record_at("old", "two\n", Reason::Close, Some("m"), 2).unwrap();
    assert!(h.rekey("old", "new"));
    assert!(h.versions("old").is_empty());
    let v = h.versions("new");
    assert_eq!(v.len(), 2);
    assert_eq!(h.text("new", v[1].id).unwrap(), "one\n");
    assert!(!h.rekey("old", "new"), "nothing left to move");
    // Merging into a key that already has a history interleaves by time.
    h.record_at("other", "mid\n", Reason::Pause, None, 1).unwrap();
    assert!(h.rekey("other", "new"));
    let v = h.versions("new");
    assert_eq!(v.len(), 3);
    assert_eq!(v.iter().map(|v| v.time).collect::<Vec<_>>(), vec![2, 1, 1]);
    for x in &v {
        assert!(h.text("new", x.id).is_some());
    }
    // New records after a merge keep ids unique.
    let id = h.record_at("new", "three\n", Reason::Pause, None, 9).unwrap();
    assert!(v.iter().all(|x| x.id != id));
}

#[test]
fn keys_lists_every_document_with_a_history() {
    let (h, _) = store();
    assert!(h.keys().is_empty());
    h.record_at("note:lib/Deep/a.md", "x", Reason::Pause, None, 1).unwrap();
    h.record_at("note:lib/Deep/b.md", "y", Reason::Pause, None, 1).unwrap();
    h.record_at("note:lib/Other.md", "z", Reason::Pause, None, 1).unwrap();
    assert_eq!(h.keys(), vec!["note:lib/Deep/a.md", "note:lib/Deep/b.md", "note:lib/Other.md"]);
    h.forget("note:lib/Other.md");
    assert_eq!(h.keys().len(), 2);
}

#[test]
fn forget_removes_everything() {
    let (h, dir) = store();
    h.record_at("a", "x", Reason::Pause, None, 1).unwrap();
    h.record_at("b", "y", Reason::Pause, None, 1).unwrap();
    h.forget("a");
    assert!(h.versions("a").is_empty());
    assert_eq!(h.versions("b").len(), 1);
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
    h.forget("never existed");
}

const H: i64 = 3600;
const D: i64 = 24 * H;

#[test]
fn retention_thins_by_age() {
    let (h, _) = store();
    let t0 = 1_000_000 * D;
    // Eight days of one snapshot every 40 minutes, ending just before `now`; one of them in the
    // daily zone carries a message.
    let now = t0 + 8 * D;
    let step = 2400;
    let count = 8 * D / step;
    for i in 0..count {
        let msg = (i == 5).then_some("keep me");
        h.record_at("r", &format!("v{i}\n"), Reason::Pause, msg, t0 + i * step).unwrap();
    }
    h.prune_at("r", now);
    let v = h.versions("r");
    let age = |x: &Version| now - x.time;
    // All of the last 24 h (72 snapshots, minus rounding) survive.
    let recent = v.iter().filter(|x| age(x) < D).count();
    assert_eq!(recent as i64, D / step - 1);
    // Between a day and a week: at most one per clock hour.
    let mut hours: Vec<i64> = v.iter().filter(|x| age(x) >= D && age(x) < 7 * D).map(|x| x.time.div_euclid(H)).collect();
    let n = hours.len();
    hours.dedup();
    assert_eq!(hours.len(), n);
    assert!((5 * 24..=6 * 24 + 1).contains(&n), "{n}");
    // Older than a week: at most one per day.
    let mut days: Vec<i64> = v.iter().filter(|x| age(x) >= 7 * D && x.message.is_none()).map(|x| x.time.div_euclid(D)).collect();
    let n = days.len();
    days.dedup();
    assert_eq!(days.len(), n);
    assert!(n <= 2);
    assert!(v.iter().any(|x| x.message.as_deref() == Some("keep me")));
    // The newest is always kept.
    assert_eq!(v[0].time, t0 + (count - 1) * step);
}

#[test]
fn retention_never_drops_messages() {
    let (h, _) = store();
    let now = 100 * D;
    // Ten snapshots on one day, 40 days ago; the middle one carries a message.
    for i in 0..10 {
        let msg = (i == 4).then_some("before the rewrite");
        h.record_at("m", &format!("t{i}\n"), Reason::Save, msg, now - 40 * D + i * 60).unwrap();
    }
    // record_at pruned relative to the old `now`, so nothing went yet; prune against the real one.
    assert_eq!(h.versions("m").len(), 10);
    let dropped = h.prune_at("m", now);
    let v = h.versions("m");
    assert_eq!(dropped, 8);
    assert_eq!(v.len(), 2);
    assert!(v.iter().any(|x| x.message.as_deref() == Some("before the rewrite")));
    // The newest of the day stays too.
    assert_eq!(h.text("m", v[0].id).unwrap(), "t9\n");
    // Dropped texts leave no files behind.
    let key_dir = std::fs::read_dir(h.dir()).unwrap().next().unwrap().unwrap().path();
    let md = std::fs::read_dir(key_dir).unwrap().filter(|e| e.as_ref().unwrap().file_name().to_string_lossy().ends_with(".md")).count();
    assert_eq!(md, 2);
}

#[test]
fn retention_caps_bytes_oldest_first() {
    let (h, _) = store();
    h.set_max_bytes(2500);
    let mut ids = vec![];
    for i in 0..6 {
        let text = format!("{}{i}\n", "x".repeat(999));
        ids.push(h.record_at("c", &text, Reason::Pause, if i == 1 { Some("pinned") } else { None }, 1000 + i).unwrap());
    }
    let v = h.versions("c");
    let total: u64 = v.iter().map(|x| x.bytes).sum();
    // The pinned one stays even though the cap is exceeded by it plus the newest.
    assert!(v.iter().any(|x| x.id == ids[1]));
    assert_eq!(v[0].id, ids[5]);
    assert!(total <= 3 * 1001, "{total}");
    assert!(h.text("c", ids[0]).is_none());
}

#[test]
fn damaged_index_is_rebuilt_from_the_text_files() {
    let (h, dir) = store();
    h.record_at("z", "one\n", Reason::Pause, None, 1).unwrap();
    h.record_at("z", "one\ntwo\n", Reason::Pause, None, 2).unwrap();
    let key_dir = std::fs::read_dir(&dir).unwrap().next().unwrap().unwrap().path();
    for damage in ["", "{\"version\": 1, \"key\": \"z\", \"entr", "garbage \u{0}", "[]"] {
        std::fs::write(key_dir.join("index.json"), damage).unwrap();
        let v = h.versions("z");
        assert_eq!(v.len(), 2, "after {damage:?}");
        assert!(v.iter().all(|x| x.reason == Reason::Recovered));
        let texts: Vec<String> = v.iter().map(|x| h.text("z", x.id).unwrap()).collect();
        assert!(texts.contains(&"one\n".to_string()) && texts.contains(&"one\ntwo\n".to_string()));
        // And recording goes on from there.
        assert!(h.record_at("z", "three\n", Reason::Pause, None, 3).is_some());
        assert_eq!(h.versions("z").len(), 3);
        h.forget("z");
        h.record_at("z", "one\n", Reason::Pause, None, 1).unwrap();
        h.record_at("z", "one\ntwo\n", Reason::Pause, None, 2).unwrap();
    }
    // A leftover temp file from an interrupted write is ignored.
    std::fs::write(key_dir.join(".index.json.tmp"), "{").unwrap();
    assert_eq!(h.versions("z").len(), 2);
}

#[test]
fn the_store_is_send_and_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<History>();
}

#[test]
fn many_threads_record_safely() {
    let (h, _) = store();
    let h = std::sync::Arc::new(h);
    let handles: Vec<_> = (0..8)
        .map(|t| {
            let h = h.clone();
            std::thread::spawn(move || {
                for i in 0..10 {
                    h.record_at("t", &format!("{t}-{i}\n"), Reason::Pause, None, 1);
                }
            })
        })
        .collect();
    for j in handles {
        j.join().unwrap();
    }
    let v = h.versions("t");
    assert_eq!(v.len(), 80);
    let mut ids: Vec<_> = v.iter().map(|x| x.id).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 80);
}

fn lines() -> impl Strategy<Value = String> {
    // Few distinct lines so the texts overlap, with and without final newline and CR.
    proptest::collection::vec(prop_oneof![Just("a\n"), Just("b\n"), Just("c\r\n"), Just("\n"), Just("d"), Just("\u{65E5}\n")], 0..30)
        .prop_map(|v| v.concat())
}

proptest! {
    #[test]
    fn diff_applied_gives_both_sides(old in lines(), new in lines()) {
        let hunks = diff_lines(&old, &new);
        prop_assert_eq!(apply(&hunks, true), old.clone());
        prop_assert_eq!(apply(&hunks, false), new.clone());
        for h in &hunks {
            match h.kind {
                DiffKind::Equal => {
                    prop_assert_eq!(&old[h.old_range.clone()], h.text.as_str());
                    prop_assert_eq!(&new[h.new_range.clone()], h.text.as_str());
                }
                DiffKind::Removed => {
                    prop_assert_eq!(&old[h.old_range.clone()], h.text.as_str());
                    prop_assert!(h.new_range.is_empty());
                }
                DiffKind::Added => {
                    prop_assert_eq!(&new[h.new_range.clone()], h.text.as_str());
                    prop_assert!(h.old_range.is_empty());
                }
            }
        }
        // Adjacent hunks differ in kind or are separated; no empty hunks.
        prop_assert!(hunks.iter().all(|h| !h.text.is_empty()));
        prop_assert!(hunks.windows(2).all(|w| w[0].kind != w[1].kind));
        // Equal texts diff to nothing but Equal.
        let same = diff_lines(&old, &old);
        prop_assert!(same.iter().all(|h| h.kind == DiffKind::Equal));
    }
}
