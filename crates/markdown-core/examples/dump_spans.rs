use markdown_core::*;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let text = std::fs::read_to_string(path).unwrap().replace("\\n", "\n");
    let d = Document::new(&text, OffsetEncoding::Utf8);
    for s in d.spans(None) {
        println!("{}..{} {:?} {:?}", s.range.start, s.range.end, s.kind, &text[s.range.start as usize..s.range.end as usize]);
    }
    println!("--- blocks");
    for b in d.blocks() { println!("{:?} {:?}", b, &text[b.range.start as usize..b.range.end as usize]); }
    println!("--- prose");
    for p in d.prose_ranges(None) { println!("{:?} {:?}", p, &text[p.start as usize..p.end as usize]); }
    println!("--- images");
    for i in d.images() { println!("{:?}", i); }
}
