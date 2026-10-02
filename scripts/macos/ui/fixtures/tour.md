---
title: A tour of the editor
tags: [markdown, test]
---

# The quiet page

Writing should feel calm. This paragraph is long enough to wrap across several lines of the text column, so that the line height, the measure and the margins can be judged at a glance, the way a reader would meet them. A misspeled word belongs here, and another one: teh.

## Lists that wrap

- A short item.
- A much longer item whose text keeps going well past the end of the first line, so the wrapped part should hang under the text and not under the dash.
  - A nested item that also runs long enough to wrap onto a second line and show its hanging indent.
- [ ] An open task with enough words to wrap around to the next line of the column.
- [x] A finished task.

1. First, numbered.
2. Second, also numbered, and long enough to wrap onto another line so the hang is visible.
10. Tenth, with a wider marker.

> A block quote that is long enough to wrap onto a second line, where the continuation should line up with the text after the marker.
>
> A second paragraph in the same quote.

## Code

Inline `code with a mispeled wrod` and a bare URL https://example.com/a-misspeled-path plus www.commonmark.org.

```swift
// A fenced block: one continuous panel, no stripes.
let greeting = "helo wrold"
for i in 0..<3 {
    print(greeting, i)
}
```

## Tables

| Name | Value | Notes |
| :--- | ----: | :---: |
| alpha | 1 | first |
| 日本語 | 22 | wide |
| emoji 🎉 | 333 | ok |

The end.
