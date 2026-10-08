//! The package around the parts: relationships, content types, the small fixed parts and the zip.

use std::collections::HashMap;
use std::io::{Cursor, Write};

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use super::look::Page;
use super::media::{self, MediaPart};
use super::xml::{escape, NAMESPACES, XML_DECLARATION};

const REL_NS: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const OFFICE_REL: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

/// The relationships of `word/document.xml`: the fixed parts, then hyperlinks and pictures as the body meets them.
pub(crate) struct Resources {
    rels: Vec<(String, String, String, bool)>,
    links: HashMap<String, String>,
    pub media: Vec<MediaPart>,
    /// Picture destination -> its relationship id.
    pictures: HashMap<String, String>,
}

impl Resources {
    pub fn new() -> Resources {
        let fixed = [
            ("styles", "styles.xml"),
            ("numbering", "numbering.xml"),
            ("footnotes", "footnotes.xml"),
            ("settings", "settings.xml"),
        ];
        let rels = fixed
            .iter()
            .enumerate()
            .map(|(n, (kind, target))| (format!("rId{}", n + 1), format!("{OFFICE_REL}/{kind}"), (*target).to_owned(), false))
            .collect();
        Resources { rels, links: HashMap::new(), media: Vec::new(), pictures: HashMap::new() }
    }

    fn add(&mut self, kind: &str, target: String, external: bool) -> String {
        let id = format!("rId{}", self.rels.len() + 1);
        self.rels.push((id.clone(), format!("{OFFICE_REL}/{kind}"), target, external));
        id
    }

    /// The relationship for an external address (the same address twice is one relationship).
    pub fn hyperlink(&mut self, url: &str) -> String {
        if let Some(id) = self.links.get(url) {
            return id.clone();
        }
        let id = self.add("hyperlink", url.to_owned(), true);
        self.links.insert(url.to_owned(), id.clone());
        id
    }

    /// The relationship for a picture's bytes, stored once per destination.
    pub fn picture(&mut self, destination: &str, ext: &'static str, bytes: &[u8]) -> String {
        if let Some(id) = self.pictures.get(destination) {
            return id.clone();
        }
        let file = format!("image{}.{ext}", self.media.len() + 1);
        let id = self.add("image", format!("media/{file}"), false);
        self.media.push(MediaPart { file, ext, bytes: bytes.to_vec() });
        self.pictures.insert(destination.to_owned(), id.clone());
        id
    }

    fn relationships_xml(&self) -> String {
        let mut x = String::from(XML_DECLARATION);
        x.push_str(&format!("<Relationships xmlns=\"{REL_NS}\">"));
        for (id, kind, target, external) in &self.rels {
            let mode = if *external { " TargetMode=\"External\"" } else { "" };
            x.push_str(&format!("<Relationship Id=\"{id}\" Type=\"{kind}\" Target=\"{}\"{mode}/>", escape(target)));
        }
        x.push_str("</Relationships>");
        x
    }

    fn content_types_xml(&self) -> String {
        let mut x = String::from(XML_DECLARATION);
        x.push_str("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">");
        x.push_str("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>");
        x.push_str("<Default Extension=\"xml\" ContentType=\"application/xml\"/>");
        let mut seen: Vec<&str> = Vec::new();
        for m in &self.media {
            if !seen.contains(&m.ext) {
                seen.push(m.ext);
                x.push_str(&format!("<Default Extension=\"{}\" ContentType=\"{}\"/>", m.ext, media::content_type(m.ext)));
            }
        }
        let word = "application/vnd.openxmlformats-officedocument.wordprocessingml";
        for (part, kind) in [("document", "document.main"), ("styles", "styles"), ("numbering", "numbering"), ("footnotes", "footnotes"), ("settings", "settings")] {
            x.push_str(&format!("<Override PartName=\"/word/{part}.xml\" ContentType=\"{word}.{kind}+xml\"/>"));
        }
        x.push_str("<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>");
        x.push_str("</Types>");
        x
    }
}

/// `word/document.xml` around a body: the namespaces, the body and the section's page.
pub(crate) fn document_xml(body: &str, page: &Page) -> String {
    format!(
        "{XML_DECLARATION}<w:document {NAMESPACES}><w:body>{body}<w:sectPr><w:pgSz w:w=\"{}\" w:h=\"{}\"/>\
<w:pgMar w:top=\"{my}\" w:right=\"{mx}\" w:bottom=\"{my}\" w:left=\"{mx}\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>",
        page.width,
        page.height,
        mx = page.margin_x,
        my = page.margin_y,
    )
}

/// `word/footnotes.xml`: the two separators Word needs and then the notes (`notes` is their `<w:footnote>` elements).
pub(crate) fn footnotes_xml(notes: &str) -> String {
    let separator = |kind: &str, id: i32, mark: &str| {
        format!(
            "<w:footnote w:type=\"{kind}\" w:id=\"{id}\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:{mark}/></w:r></w:p></w:footnote>"
        )
    };
    format!(
        "{XML_DECLARATION}<w:footnotes {NAMESPACES}>{}{}{notes}</w:footnotes>",
        separator("separator", -1, "separator"),
        separator("continuationSeparator", 0, "continuationSeparator")
    )
}

fn settings_xml() -> String {
    format!(
        "{XML_DECLARATION}<w:settings {NAMESPACES}><w:defaultTabStop w:val=\"720\"/><w:characterSpacingControl w:val=\"doNotCompress\"/>\
<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>\
<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"
    )
}

fn core_xml(title: &str) -> String {
    format!(
        "{XML_DECLARATION}<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" \
xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\
<dc:title>{}</dc:title></cp:coreProperties>",
        escape(title)
    )
}

/// The parts of a finished document, ready to zip.
pub(crate) struct Parts {
    pub document: String,
    pub styles: String,
    pub numbering: String,
    pub footnotes: String,
    pub title: String,
    pub resources: Resources,
}

/// The package as bytes: `[Content_Types].xml` first, as the format asks. Empty only if the in-memory zip fails, which
/// it does not do.
pub(crate) fn zip(parts: Parts) -> Vec<u8> {
    let write = || -> Result<Vec<u8>, zip::result::ZipError> {
        let mut z = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        let mut put = |name: &str, bytes: &[u8]| -> Result<(), zip::result::ZipError> {
            z.start_file(name, options)?;
            z.write_all(bytes)?;
            Ok(())
        };
        put("[Content_Types].xml", parts.resources.content_types_xml().as_bytes())?;
        let root = format!(
            "{XML_DECLARATION}<Relationships xmlns=\"{REL_NS}\">\
<Relationship Id=\"rId1\" Type=\"{OFFICE_REL}/officeDocument\" Target=\"word/document.xml\"/>\
<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>\
</Relationships>"
        );
        put("_rels/.rels", root.as_bytes())?;
        put("docProps/core.xml", core_xml(&parts.title).as_bytes())?;
        put("word/document.xml", parts.document.as_bytes())?;
        put("word/_rels/document.xml.rels", parts.resources.relationships_xml().as_bytes())?;
        put("word/styles.xml", parts.styles.as_bytes())?;
        put("word/numbering.xml", parts.numbering.as_bytes())?;
        put("word/footnotes.xml", parts.footnotes.as_bytes())?;
        put("word/settings.xml", settings_xml().as_bytes())?;
        for m in &parts.resources.media {
            put(&format!("word/media/{}", m.file), &m.bytes)?;
        }
        Ok(z.finish()?.into_inner())
    };
    write().unwrap_or_default()
}
