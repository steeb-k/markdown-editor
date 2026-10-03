# Languages

```rust
// A comment
use std::collections::HashMap;

#[derive(Debug)]
pub struct Point<T> {
    x: T,
}

fn main() {
    let name = "world";
    let n: u32 = 42;
    println!("hello {name} {n}");
}
```

```python
import os

class Greeter(Base):
    """Doc."""
    def greet(self, name: str) -> str:
        return f"hi {name}" + str(3.5)  # trailing
```

```js
const total = items.map((x) => x * 2).filter(Boolean);
/* block
   comment */
export default async function load(url) { return await fetch(`${url}/x`); }
```

```ts
interface Shape { area(): number }
type Id = string | number;
```

```json
{ "name": "core", "version": 1.5, "ok": true, "tags": [null] }
```

```yaml
name: demo
steps:
  - run: echo hi # note
```

```toml
[package]
name = "core"
edition = 2024
```

```html
<!-- page -->
<div class="a" id='b'>text</div>
```

```css
.card > a:hover { color: #fff; margin: 0 auto; }
```

```sh
# deploy
if [ -f "$FILE" ]; then echo "found" | tee out.txt; fi
```

```c
#include <stdio.h>
int main(void) { printf("%d\n", 0x1F); return 0; }
```

```go
package main

func main() { var s string = "x"; _ = s }
```

```sql
SELECT id, name FROM users WHERE age > 21 -- adults
ORDER BY name;
```

```swift
struct Item: Codable { var count: Int = 0 }
let a = Item(count: 3) // make
```
