# Code in the editor

Some prose before the code, long enough to be a paragraph of its own, so the caret has somewhere to rest that is not a block.

```rust
// Greets the world, then counts.
use std::fmt;

fn main() {
    let name = "world";
    let count: u32 = 42;
    println!("hello {name} {count}");
}
```

A paragraph between the blocks.

```python {.numberLines}
class Greeter:
    """Says hello."""
    def greet(self, name):
        return f"hello {name}" + str(3.5)  # trailing note
```

```js title="greet.js"
const greet = (name) => `hello ${name}`; // arrow
export default async function load(url) { return await fetch(url); }
```

A block in a language the highlighter does not know, and one with no language at all. Neither has a badge.

```nosuchlanguage
fn plain() { let x = 1; }
```

```
fn nolanguage() { let y = 2; }
```

- A list item with a fenced block:

  ```sh
  # deploy
  if [ -f "$FILE" ]; then echo "found" | tee out.txt; fi
  ```

> A quote with a block:
>
> ```go
> func main() { var s string = "x"; _ = s }
> ```

A block whose first line runs under the badge:

```json
{ "name": "a long first line that keeps going across the whole column so the badge would sit on top of it", "version": 1.5, "ok": true }
```

A fence whose info string runs the whole width:

```rust,ignore,edition2021,no_run,should_panic,this_is_a_deliberately_long_info_string_that_fills_the_line
let long_info = 1;
```

Closing prose, last.
