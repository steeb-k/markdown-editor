# Edge cases

> # A heading inside a quote
> Quote text with **bold** and a list:
>
> - item one in a quote
> - [ ] a task in a quote
>
> > A nested quote that is long enough to wrap onto a second line, to see how both bars and the hanging indent behave together.

- A list item with a fence:

  ```sh
  echo "inside a list"
  ```

- Another item with an image reference ![inline](images/sample.png) in the middle of its text.
- Autolink <https://example.com/auto> and a footnote[^1], and a [reference link][ref].

[^1]: The footnote text, with a label that stays visible.

[ref]: https://example.com/ref "A title"

Hard break with a backslash\
second line, and trailing spaces  
third line.

<div>Raw HTML stays visible and dim.</div>

    indented code stays as it is

Paragraph before an unclosed fence.

```python
def unclosed():
    return "no closing fence"
