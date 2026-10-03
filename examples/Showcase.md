---
title: Showcase
tags: [showcase, demo/everything]
author: You
---

# Showcase: every element in one file

This document exercises everything the editor knows about. Open it in Source and in Live (⌥⌘1 / ⌥⌘2), switch layouts (⌥⌘3, 4, 5), turn on Focus (⌘D) and parts of speech (⇧⌘D), and change the theme and font in Settings. To see wikilinks, tags and backlinks, add the `examples` folder as a library root (Library ▸ Add Folder…) and turn on Notes Mode (⌃⌘L); [[Linked Note]] lives beside this file.

## Headings

### Level three

#### Level four

##### Level five

###### Level six

Setext style
============

Also setext
-----------

## Inline formatting

Plain text with *emphasis*, **strong**, ***both***, ~~strikethrough~~ and `inline code`. Underscores work too: _emphasis_ and __strong__. A hard line break follows this line  
and this is the next line. A backslash break\
works as well.

Intraword: snake_case_name stays plain, but *a*n*d* this has emphasis around a letter. Escapes: \*not emphasis\*, \`not code\`, \# not a heading.

Inline HTML: <kbd>⌘</kbd> + <kbd>K</kbd>, a <sup>superscript</sup>, and <span style="color: red">a styled span</span> (the preview strips what it does not allow).

## Links

An [inline link](https://commonmark.org "CommonMark"), a [reference link][spec], a [collapsed one][] and a [shortcut one]. Autolinks: <https://github.com> and a bare URL https://daringfireball.net/projects/markdown/ pasted straight in, plus http://localhost:3000/dev for the local case. An email: <someone@example.com>.

[spec]: https://spec.commonmark.org/
[collapsed one]: https://github.github.com/gfm/
[shortcut one]: https://pulldown-cmark.github.io/pulldown-cmark/

⌘-click a link to open it. In Live mode the brackets and the destination are concealed until the caret is inside.

## Images

A picture on its own line shows inline in Live mode and in the preview:

![A harbour at dusk](img/harbour.png "Harbour")

A smaller one, and one inside a sentence ![tiny](img/small.png) like this.

![Sample](img/sample.png)

A missing picture: ![nothing here](img/missing.png) — the editor shows the source, the preview a broken image.

## Lists

- Bullet one
- Bullet two, with *emphasis* and a [link](https://example.com)
  - Nested bullet
    - Nested deeper
  - Back out one
- Bullet three

1. Numbered one
2. Numbered two
   1. Nested numbered
   2. Another
3. Numbered three

1) Parenthesis style
2) Also numbered

* Star bullets
+ Plus bullets

- [ ] A task to do
- [x] A task done
- [ ] Another, with a `code span`
  - [ ] A nested task

A list item with more than one paragraph:

- First paragraph of the item.

  Second paragraph of the same item, indented.

  ```sh
  echo "a code block inside a list item"
  ```

- The next item.

Press Return at the end of an item to continue the list; Return on an empty item ends it. Tab and Shift-Tab indent and outdent.

## Block quotes

> A quotation, which may run over
> several lines of the source.
>
> > Nested quotation.
>
> - A list inside a quote
> - With two items
>
> ```python
> print("code inside a quote")
> ```

## Code

Inline `code` and fenced blocks. Each block with a known language gets a badge at its top-right; click it to change the language.

```rust
/// Rust: the core is written in it.
pub fn greet(name: &str) -> String {
    let count = 3_usize;
    format!("Hello, {name}! ({count})")
}
```

```python
import json

def load(path: str) -> dict:
    """Python with a docstring."""
    with open(path) as f:
        return json.load(f)
```

```javascript
const greet = (name = "world") => `Hello, ${name}!`;
export default greet;
```

```typescript
interface Note { title: string; tags: string[] }
function first<T>(xs: T[]): T | undefined { return xs[0]; }
```

```swift
struct Point: Hashable { var x: Double; var y: Double }
let p = Point(x: 1, y: 2)
print("\(p.x), \(p.y)")
```

```go
package main

import "fmt"

func main() { fmt.Println("Go") }
```

```c
#include <stdio.h>
int main(void) { printf("C\n"); return 0; }
```

```sh
#!/bin/sh
for f in *.md; do
  wc -w "$f"
done
```

```json
{ "name": "markdown", "version": 1, "tags": ["editor", "notes"], "ok": true }
```

```yaml
name: markdown
features:
  - focus
  - live
```

```toml
[package]
name = "markdown-core"
edition = "2021"
```

```html
<article class="note">
  <h1>HTML</h1>
  <p>With <em>inline</em> tags.</p>
</article>
```

```css
.note { color: #333; margin: 0 auto; }
.note:hover { background: rgb(240, 240, 240); }
```

```sql
SELECT title, count(*) AS n FROM notes WHERE tag = 'demo' GROUP BY title;
```

```markdown
# Markdown inside Markdown
- with *a list*
```

```diff
- removed line
+ added line
```

```klingon
This language is unknown, so there is no badge and no colours.
```

```
No language at all: plain monospace, no badge.
```

    An indented code block (four spaces). Never highlighted.

~~~ruby
puts "tilde fences work too"
~~~

A long block, for scrolling and for the badge staying put:

```rust
fn fib(n: u64) -> u64 {
    match n {
        0 => 0,
        1 => 1,
        _ => fib(n - 1) + fib(n - 2),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_values() {
        assert_eq!(fib(0), 0);
        assert_eq!(fib(1), 1);
        assert_eq!(fib(10), 55);
    }
}
```

## Tables

| Left | Centre | Right |
|:-----|:------:|------:|
| a    |   b    |     c |
| longer cell | *emphasis* | `code` |
| 1    |   2    |     3 |

Tab moves between cells; Return in the last row adds one. Try the Table menu for rows and columns, and Insert Table… (⌥⌘T) for a new one.

A table without alignment and without leading pipes:

Name | Value
--- | ---
one | 1
two | 2

## Footnotes

Here is a claim with a footnote[^1], and another[^long].

[^1]: The footnote's text.
[^long]: A longer footnote.

    With a second paragraph, indented.

## Thematic breaks

Three forms:

---

***

___

## Wikilinks and tags

These need the library (Notes Mode, with `examples` as a root). [[Linked Note]] is a plain wikilink; [[Linked Note|with a label]] shows the label; [[Linked Note#A heading in it]] jumps to a heading; [[Nowhere]] does not resolve, and ⌘-clicking it offers to create the note. ⌥⌘B shows what links here.

Inline tags: #showcase, #demo/everything and #unicodé. Tags from the front matter count too. A `#` with a space after it is a heading, not a tag, and `#inside code` is not a tag.

## Focus mode and parts of speech

This paragraph exists so there is something to focus on. Focus mode dims everything but the current sentence or paragraph (the scope is a setting) and keeps the line in the middle of the window. The highlighter colours nouns, verbs, adjectives, adverbs and conjunctions differently; it understands more than one language, so hier ist ein deutscher Satz mit einem langen Wort, et voici une phrase en français qui parle de la mer et du vent.

Walking along the harbour wall at dusk, she counted the boats coming in: three trawlers, a lifeboat on exercise, and a yacht that had plainly misjudged the tide. The quickest of them cut its engine early and drifted the last few metres, which the harbour master clearly did not appreciate. Nobody said anything. The gulls, as ever, had opinions.

## Unicode

Emoji 🎉 👨‍👩‍👧 🇩🇪, CJK 日本語のテキスト 中文 한국어, right-to-left العربية עברית, combining marks é (decomposed é) and café (precomposed), and a line with a tab	character. The caret and the selection should step over each of these as one unit.

## Front matter, HTML blocks and raw bits

The YAML at the top of this file is front matter: dimmed in the editor, used for the title and tags, never rendered.

<details>
<summary>An HTML block</summary>

Markdown *inside* an HTML block renders when there is a blank line around it.

</details>

<!-- An HTML comment: invisible in the preview, visible in Source. -->

## Authorship

Use Edit ▸ Paste As ▸ AI (⇧⌘V) or Reference (⌃⌘V) to paste borrowed text, or select some and use Mark As (⌃⌘1/2/3). Show Authorship (⌥⌘A) colours it; the marks are saved in the file in the reference editor's annotation format. `fixtures/authorship/harbour-lights.md` in the repository has six authors already marked.

## Export

File ▸ Export as PDF…, Print (⌘P), and Edit ▸ Copy As ▸ HTML or Rich Text for pasting into other apps.

The end.
