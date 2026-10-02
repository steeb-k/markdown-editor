//! Conversion between UTF-8 byte offsets (internal) and the document's offset unit (public).
//!
//! A checkpoint table (byte, unit) every ~256 bytes makes single conversions O(256) and
//! lets a monotone sweep ([`Cursor`]) convert a whole span list in one forward pass.

use crate::types::OffsetEncoding;

const STRIDE: usize = 256;

#[derive(Debug, Clone)]
pub(crate) struct OffsetMap {
    enc: OffsetEncoding,
    total_units: usize,
    /// Always starts with (0, 0). Empty for Utf8.
    cps: Vec<(u32, u32)>,
}

/// Units contributed by a byte slice that starts and ends on code point boundaries.
#[inline]
fn units(enc: OffsetEncoding, bytes: &[u8]) -> usize {
    match enc {
        OffsetEncoding::Utf8 => bytes.len(),
        OffsetEncoding::Utf32 => bytes.iter().map(|&b| ((b & 0xC0) != 0x80) as usize).sum(),
        OffsetEncoding::Utf16 => bytes
            .iter()
            .map(|&b| ((b & 0xC0) != 0x80) as usize + (b >= 0xF0) as usize)
            .sum(),
    }
}

impl OffsetMap {
    pub fn new(text: &str, enc: OffsetEncoding) -> Self {
        let bytes = text.as_bytes();
        if enc == OffsetEncoding::Utf8 {
            return Self { enc, total_units: bytes.len(), cps: Vec::new() };
        }
        let mut cps = Vec::with_capacity(bytes.len() / STRIDE + 1);
        cps.push((0u32, 0u32));
        let (mut byte, mut unit) = (0usize, 0usize);
        while byte + STRIDE < bytes.len() {
            let mut next = byte + STRIDE;
            // (A code point that straddles the stride may run to the very end of the text.)
            while next < bytes.len() && (bytes[next] & 0xC0) == 0x80 {
                next += 1;
            }
            unit += units(enc, &bytes[byte..next]);
            byte = next;
            cps.push((byte as u32, unit as u32));
        }
        unit += units(enc, &bytes[byte..]);
        Self { enc, total_units: unit, cps }
    }

    pub fn len_units(&self) -> usize {
        self.total_units
    }

    /// Byte offset (a code point boundary) to unit offset.
    pub fn byte_to_unit(&self, text: &str, byte: usize) -> usize {
        self.cursor(text).to(byte)
    }

    /// Locate a unit offset: the byte offset of the code point containing it and
    /// whether the unit offset is exactly at that code point's start. `None` if
    /// beyond the end.
    pub fn locate_unit(&self, text: &str, unit: usize) -> Option<(usize, bool)> {
        if unit > self.total_units {
            return None;
        }
        if self.enc == OffsetEncoding::Utf8 {
            let mut b = unit;
            while !text.is_char_boundary(b) {
                b -= 1;
            }
            return Some((b, b == unit));
        }
        if unit == self.total_units {
            return Some((text.len(), true));
        }
        let i = self.cps.partition_point(|c| c.1 as usize <= unit) - 1;
        let (mut byte, mut u) = (self.cps[i].0 as usize, self.cps[i].1 as usize);
        for ch in text[byte..].chars() {
            if u == unit {
                return Some((byte, true));
            }
            let w = if self.enc == OffsetEncoding::Utf16 { ch.len_utf16() } else { 1 };
            if u + w > unit {
                return Some((byte, false));
            }
            u += w;
            byte += ch.len_utf8();
        }
        Some((byte, u == unit))
    }

    pub fn cursor<'a>(&'a self, text: &'a str) -> Cursor<'a> {
        Cursor { map: self, bytes: text.as_bytes(), byte: 0, unit: 0 }
    }
}

/// Monotone byte-to-unit converter. Converting offsets in ascending order costs one
/// forward pass over the text; going backwards re-seats from a checkpoint.
pub(crate) struct Cursor<'a> {
    map: &'a OffsetMap,
    bytes: &'a [u8],
    byte: usize,
    unit: usize,
}

impl Cursor<'_> {
    pub fn to(&mut self, target: usize) -> usize {
        let target = target.min(self.bytes.len());
        if self.map.enc == OffsetEncoding::Utf8 {
            return target;
        }
        if target < self.byte || target - self.byte > 2 * STRIDE {
            let i = self.map.cps.partition_point(|c| c.0 as usize <= target) - 1;
            self.byte = self.map.cps[i].0 as usize;
            self.unit = self.map.cps[i].1 as usize;
        }
        self.unit += units(self.map.enc, &self.bytes[self.byte..target]);
        self.byte = target;
        self.unit
    }
}
