//! Word export: `Document::render_docx` writes a `.docx`, a zip of WordprocessingML parts.
//!
//! Walked from pulldown-cmark's events, as the HTML and plain-text writers are, and styled by the document's template:
//! `styles.xml` is built from the resolved [`TemplateSpec`] and the editor's typography the way [`crate::template_css`]
//! builds the preview's stylesheet, so a document in the Academic template exports looking like Academic. A template's
//! `custom.css` is CSS and is not read. The core reads no files: pictures come in as bytes ([`ImageData`]).
//!
//! One module per part of the package: [`package`] (relationships, content types and the zip), [`body`] (the document and
//! footnotes), [`styles`], [`numbering`], [`media`] (picture formats) and [`look`] (the template resolved for Word).

mod body;
mod look;
mod media;
mod numbering;
mod package;
mod styles;
mod xml;

use crate::document::Document;
use crate::preview_css::Typography;
use crate::render::{ImageData, ImageSize};
use crate::template::TemplateSpec;
use crate::walk::Tree;

use self::body::Body;
use self::look::Look;
use self::numbering::Numbering;
use self::package::{document_xml, footnotes_xml, Parts, Resources};

/// What to write and how it is set.
#[derive(Debug, Clone)]
pub struct DocxOptions {
    /// The title for the file's properties when the document has neither a front matter `title:` nor a heading.
    pub title: String,
    /// The resolved template (the empty spec is the Default template).
    pub spec: TemplateSpec,
    /// The editor's fonts, where the template says `body` or `mono` (or nothing).
    pub typography: Typography,
    /// The pictures' sizes in points, for the destination as written; without one the picture's own pixels are used.
    pub image_sizes: Vec<ImageSize>,
    /// The pictures' bytes. A picture with none is written as its alt text.
    pub image_data: Vec<ImageData>,
    /// The paper in points; zero is US Letter.
    pub page_width_pt: f64,
    pub page_height_pt: f64,
}

impl Default for DocxOptions {
    fn default() -> Self {
        Self {
            title: String::new(),
            spec: TemplateSpec::default(),
            typography: Typography::default(),
            image_sizes: Vec::new(),
            image_data: Vec::new(),
            page_width_pt: 0.0,
            page_height_pt: 0.0,
        }
    }
}

impl Document {
    /// The document as a `.docx` file's bytes. Front matter, raw HTML and the annotation block are not in it.
    pub fn render_docx(&self, options: &DocxOptions) -> Vec<u8> {
        let look = Look::new(options);
        let mut resources = Resources::new();
        let mut numbering = Numbering::new(&look);
        let text = self.text();
        let mut title = options.title.clone();
        let (body, notes) = match Tree::parse(text) {
            Some(tree) => {
                // The document's own title (front matter, else the first heading) before the shell's fallback.
                if let Some(t) = tree.title() {
                    title = t;
                }
                let mut body = Body::new(&tree, &look, &mut resources, &mut numbering);
                let main = body.document();
                (main, body.footnotes())
            }
            // The parser failed on this text: its lines are the paragraphs.
            None => {
                let empty = Tree { src: text, events: Vec::new(), end_of: Vec::new() };
                let mut body = Body::new(&empty, &look, &mut resources, &mut numbering);
                (body.lines(text), String::new())
            }
        };
        let page = look.page();
        let parts = Parts {
            document: document_xml(&body, &page),
            styles: styles::styles_xml(&look, numbering.heading_id()),
            numbering: numbering.xml(),
            footnotes: footnotes_xml(&notes),
            title,
            resources,
        };
        package::zip(parts)
    }
}
