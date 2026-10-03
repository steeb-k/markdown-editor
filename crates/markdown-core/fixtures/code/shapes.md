# Shapes of fenced code

Tilde fence with attributes after the language:

~~~rust,ignore
fn tilde() -> bool { true }
~~~

Attributes in braces, and a leading dot:

``` {.python .numberLines}
x = [1, 2, 3]
```

```.js
let dotted = 1;
```

Inside a block quote, with a blank line:

> ```python
> def quoted(a):
>
>     return "q"  # in a quote
> ```

Inside a list item:

- item

  ```rust
  let in_list = 'c';

  // after a blank line
  ```

Indented three spaces:

   ```sh
   echo indented
   ```

Wide characters before the code on the line:

```js
const s = "héllo 🎉 wörld"; // 🎉 emoji
```

No language, an unknown one, and indented code (all plain):

```
fn plain() {}
```

```nosuchlanguage
fn unknown() {}
```

    fn indented() {}

An unclosed fence runs to the end of the document:

```rust
let open = 1;
