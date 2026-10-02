//! How long the bundled syntaxes take to load, how many there are, and which common languages
//! highlight.
//!
//!   cargo run --release -p markdown-core --example highlight_load
use markdown_core::highlight;
use std::time::Instant;

fn main() {
    let t = Instant::now();
    highlight::warm_up();
    println!("syntax set loaded in {:.1} ms; {} syntaxes", t.elapsed().as_secs_f64() * 1e3, highlight::language_names().len());
    for lang in [
        "rust", "python", "js", "ts", "typescript", "tsx", "jsx", "toml", "swift", "kotlin", "dockerfile", "go", "java", "c", "cpp", "cs", "ruby",
        "php", "sh", "bash", "zsh", "sql", "json", "yaml", "html", "css", "scss", "xml", "diff", "make", "makefile", "lua", "perl", "r", "haskell",
        "scala", "ini", "nginx", "graphql", "proto", "terraform", "hcl", "dart", "zig", "elixir", "erlang", "clojure", "powershell", "vue", "svelte",
        "latex", "tex", "csv", "env", "gitignore", "cmake", "objc", "m", "groovy", "julia", "nim", "ocaml", "fsharp", "vim", "asm", "jsonc", "json5",
    ] {
        let t = Instant::now();
        let ok = highlight::is_highlightable(lang, "x = 1\n");
        let _ = highlight::highlight(lang, "let x = 1;\n");
        println!("{:12} {}  ({:.2} ms)", lang, if ok { "yes" } else { "-" }, t.elapsed().as_secs_f64() * 1e3);
    }
}
