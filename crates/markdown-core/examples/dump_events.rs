use pulldown_cmark::*;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let text = std::fs::read_to_string(path).unwrap().replace("\\n", "\n");
    let o = Options::ENABLE_TABLES | Options::ENABLE_FOOTNOTES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    for (e, r) in Parser::new_ext(&text, o).into_offset_iter() {
        println!("{:?} {:?}  {:?}", r, &text[r.clone()], e);
    }
}
