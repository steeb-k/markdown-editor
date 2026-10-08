//! Pictures: which formats Word takes, how big a picture is by its own header, and the parts that carry them.

/// The file extension Word knows a picture by, from the type the shell says and, failing that, the bytes themselves.
pub(crate) fn extension(mime: &str, bytes: &[u8]) -> Option<&'static str> {
    let by_mime = match mime.trim().to_ascii_lowercase().as_str() {
        "image/png" => Some("png"),
        "image/jpeg" | "image/jpg" | "image/pjpeg" => Some("jpeg"),
        "image/gif" => Some("gif"),
        "image/bmp" => Some("bmp"),
        "image/tiff" => Some("tiff"),
        _ => None,
    };
    let by_bytes = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpeg")
    } else if bytes.starts_with(b"GIF8") {
        Some("gif")
    } else if bytes.starts_with(b"BM") {
        Some("bmp")
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        Some("tiff")
    } else {
        None
    };
    // The bytes win: a file called .png that is a JPEG is a JPEG to Word.
    by_bytes.or(by_mime)
}

/// The content type of an extension from [`extension`].
pub(crate) fn content_type(ext: &str) -> &'static str {
    match ext {
        "png" => "image/png",
        "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        _ => "image/tiff",
    }
}

/// The width and height in pixels, read from the header of the formats that are easy to read.
pub(crate) fn dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let be32 = |at: usize| bytes.get(at..at + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]));
    let le16 = |at: usize| bytes.get(at..at + 2).map(|b| u32::from(u16::from_le_bytes([b[0], b[1]])));
    let le32 = |at: usize| bytes.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    if bytes.starts_with(b"\x89PNG") {
        return Some((be32(16)?, be32(20)?));
    }
    if bytes.starts_with(b"GIF8") {
        return Some((le16(6)?, le16(8)?));
    }
    if bytes.starts_with(b"BM") {
        return Some((le32(18)?, (le32(22)? as i32).unsigned_abs()));
    }
    if bytes.starts_with(&[0xFF, 0xD8]) {
        // Segments until a start-of-frame marker.
        let mut i = 2;
        while i + 9 < bytes.len() {
            if bytes[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = bytes[i + 1];
            if marker == 0xFF || marker == 0x01 || (0xD0..=0xD8).contains(&marker) {
                i += if marker == 0xFF { 1 } else { 2 };
                continue;
            }
            let length = usize::from(u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]));
            if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
                let h = u32::from(u16::from_be_bytes([bytes[i + 5], bytes[i + 6]]));
                let w = u32::from(u16::from_be_bytes([bytes[i + 7], bytes[i + 8]]));
                return Some((w, h));
            }
            i += 2 + length;
        }
    }
    None
}

/// A picture stored in the package.
pub(crate) struct MediaPart {
    /// `image1.png`: the file under `word/media/`.
    pub file: String,
    pub ext: &'static str,
    pub bytes: Vec<u8>,
}
