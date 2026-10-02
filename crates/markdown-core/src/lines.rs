//! Line index over UTF-8 text. Line terminators: `\n`, `\r\n`, lone `\r`.

#[derive(Debug, Clone)]
pub(crate) struct LineIndex {
    /// Start offset of every line. The last entry may equal `len` (empty last line).
    starts: Vec<usize>,
    len: usize,
}

impl LineIndex {
    pub fn new(text: &str) -> Self {
        let b = text.as_bytes();
        let mut starts = Vec::with_capacity(b.len() / 40 + 1);
        starts.push(0);
        let mut i = 0;
        while i < b.len() {
            match b[i] {
                b'\n' => starts.push(i + 1),
                b'\r' => {
                    if b.get(i + 1) == Some(&b'\n') {
                        i += 1;
                    }
                    starts.push(i + 1);
                }
                _ => {}
            }
            i += 1;
        }
        Self { starts, len: b.len() }
    }

    pub fn count(&self) -> usize {
        self.starts.len()
    }

    /// 0-based line containing byte offset `pos` (a position between `\r` and `\n`
    /// belongs to the line the CRLF terminates).
    pub fn line_of(&self, pos: usize) -> usize {
        self.starts.partition_point(|&s| s <= pos).saturating_sub(1)
    }

    pub fn line_start(&self, pos: usize) -> usize {
        self.starts[self.line_of(pos)]
    }

    /// Start of the line after the one containing `pos` (or the text length).
    pub fn next_line_start(&self, pos: usize) -> usize {
        let i = self.starts.partition_point(|&s| s <= pos);
        self.starts.get(i).copied().unwrap_or(self.len)
    }

    pub fn is_line_start(&self, pos: usize) -> bool {
        self.starts.binary_search(&pos).is_ok()
    }

    /// `(start, end)` of a line without its terminator.
    pub fn line_range(&self, line: usize, bytes: &[u8]) -> (usize, usize) {
        let s = self.starts[line];
        let mut e = self.starts.get(line + 1).copied().unwrap_or(self.len);
        if e > s && bytes[e - 1] == b'\n' {
            e -= 1;
        }
        if e > s && bytes[e - 1] == b'\r' {
            e -= 1;
        }
        (s, e)
    }
}
