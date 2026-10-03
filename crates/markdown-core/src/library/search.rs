//! The inverted index behind full-text search: case-folded words, prefix queries, AND of terms.

use std::collections::{BTreeMap, HashMap};

/// A posting: the note's slot and `tf << 1 | in_title`.
type Posting = (u32, u32);

#[derive(Debug, Default, Clone)]
pub(crate) struct Inverted {
    /// Term to id, ordered, so a prefix is a range.
    dict: BTreeMap<String, u32>,
    /// By id: the term (to leave the dictionary when its last posting goes) and its postings,
    /// sorted by note slot.
    terms: Vec<(String, Vec<Posting>)>,
    free: Vec<u32>,
}

/// What a query found in one note.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Found {
    pub slot: u32,
    /// Number of query terms that match a word of the title (or file name).
    pub title_terms: u32,
    pub tf: u32,
}

impl Inverted {
    fn intern(&mut self, term: &str) -> u32 {
        if let Some(&id) = self.dict.get(term) {
            return id;
        }
        let id = match self.free.pop() {
            Some(id) => {
                self.terms[id as usize] = (term.to_owned(), Vec::new());
                id
            }
            None => {
                self.terms.push((term.to_owned(), Vec::new()));
                (self.terms.len() - 1) as u32
            }
        };
        self.dict.insert(term.to_owned(), id);
        id
    }

    /// Indexes a note: its body terms with their counts and its title words. Returns the term
    /// ids to hand back to [`Inverted::remove`].
    pub fn add(&mut self, slot: u32, body: &[(String, u32)], title: &[String]) -> Vec<u32> {
        let mut ids: Vec<u32> = Vec::with_capacity(body.len() + title.len());
        let mut entries: Vec<(u32, u32)> = Vec::with_capacity(body.len() + title.len());
        for (term, tf) in body {
            let id = self.intern(term);
            ids.push(id);
            entries.push((id, tf.min(&(u32::MAX >> 1)) << 1));
        }
        let mut position: HashMap<u32, usize> = HashMap::new();
        if !title.is_empty() {
            position = entries.iter().enumerate().map(|(k, e)| (e.0, k)).collect();
        }
        for term in title {
            let id = self.intern(term);
            match position.get(&id) {
                Some(&k) => entries[k].1 |= 1,
                None => {
                    position.insert(id, entries.len());
                    entries.push((id, 1));
                    ids.push(id);
                }
            }
        }
        for (id, packed) in entries {
            let list = &mut self.terms[id as usize].1;
            match list.last() {
                Some(&(last, _)) if last < slot => list.push((slot, packed)),
                None => list.push((slot, packed)),
                _ => {
                    let at = list.partition_point(|p| p.0 < slot);
                    list.insert(at, (slot, packed));
                }
            }
        }
        ids
    }

    /// Takes a note out again.
    pub fn remove(&mut self, slot: u32, ids: &[u32]) {
        for &id in ids {
            let list = &mut self.terms[id as usize].1;
            if let Ok(at) = list.binary_search_by_key(&slot, |p| p.0) {
                list.remove(at);
            }
            if list.is_empty() {
                let term = std::mem::take(&mut self.terms[id as usize].0);
                self.dict.remove(&term);
                self.free.push(id);
            }
        }
    }

    /// Notes holding, for every term of `query`, a word starting with it. `slots` is the number
    /// of note slots (for the scratch space). Unordered.
    pub fn query(&self, query: &[String], slots: usize) -> Vec<Found> {
        let mut result: Option<Vec<Found>> = None;
        let mut seen: Vec<&String> = Vec::new(); // a repeated word does not count twice
        let mut tf: Vec<u32> = vec![0; slots];
        let mut state: Vec<u8> = vec![0; slots]; // 0 untouched, 1 touched, 2 touched, in the title
        let mut touched: Vec<u32> = Vec::new();
        for term in query {
            if seen.contains(&term) {
                continue;
            }
            seen.push(term);
            let from = (std::ops::Bound::Included(term.as_str()), std::ops::Bound::Unbounded);
            for (word, &id) in self.dict.range::<str, _>(from) {
                if !word.starts_with(term.as_str()) {
                    break;
                }
                for &(slot, packed) in &self.terms[id as usize].1 {
                    let s = slot as usize;
                    if state[s] == 0 {
                        state[s] = 1;
                        touched.push(slot);
                    }
                    tf[s] = tf[s].saturating_add(packed >> 1);
                    if packed & 1 == 1 {
                        state[s] = 2;
                    }
                }
            }
            let this = |slot: u32| (tf[slot as usize], u32::from(state[slot as usize] == 2));
            result = Some(match result.take() {
                None => touched
                    .iter()
                    .map(|&slot| {
                        let (tf, t) = this(slot);
                        Found { slot, title_terms: t, tf }
                    })
                    .collect(),
                Some(prev) => prev
                    .into_iter()
                    .filter(|f| state[f.slot as usize] != 0)
                    .map(|f| {
                        let (tf, t) = this(f.slot);
                        Found { slot: f.slot, title_terms: f.title_terms + t, tf: f.tf.saturating_add(tf) }
                    })
                    .collect(),
            });
            for slot in touched.drain(..) {
                tf[slot as usize] = 0;
                state[slot as usize] = 0;
            }
            if result.as_ref().is_some_and(Vec::is_empty) {
                break;
            }
        }
        result.unwrap_or_default()
    }
}
