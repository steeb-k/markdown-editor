# Welcome to Markdown

This page is a Markdown document, and it is yours: change it, break it, close it without saving. Everything below works on it right now.

Markdown is plain text with a few marks that mean something: `#` makes a heading, `*` or `_` makes *emphasis*, two of them make **strong** text. The file stays plain text, so any other program can read it, and it will outlive this one.

## Two ways of seeing your words

**Source** shows every mark, dimmed, so you can see exactly what you wrote. **Live** hides the marks until the caret touches the thing they belong to: put the caret inside a **bold word** and the stars appear; move away and they go. The text on disk is the same either way. Choose in the View menu (Source, Live). Which one new windows start in is a setting.

Beside the editor you can have a preview: **Editor and Preview** puts the two side by side and keeps them scrolled together; **Preview** shows the finished page alone. Pictures, tables, footnotes and highlighted code blocks look as they will when you print or export.

View > Show Outline (⌃⌘O) or Show History (⌃⌘H) puts one column on the right, in every layout, with two panes you switch between at its top: **Outline** lists the document's headings (click one to go there, and the editor and the preview both scroll to it; use the arrow keys and Return; fold a level with its triangle) and marks the one you are reading, following the scroll rather than the caret, and **History** (see below). One width, one toggle; View > Show History shows the column on History. Which windows start with it, and on which pane, are settings.

## Writing

Type. Press Return at the end of a list item and the list goes on; press it on an empty item and the list ends. Tab and Shift-Tab indent and outdent items.

- Wrap the selection in marks from the Format menu: Strong, Emphasis, Strikethrough, Inline Code, Link.
- Pick a heading level from Format > Heading, or toggle a quote, a list, a task list or a code block.
- [ ] A task is a list item that starts with `[ ]`.
- [x] In Live mode the box is drawn as a checkbox: click it to check the task off.

> A quote is a paragraph that starts with `>`.

```swift
// Fenced code is highlighted in the preview and in exported PDFs.
let greeting = "Hello, Markdown"
print(greeting)
```

Bare links such as https://commonmark.org/help/ are links without any marks, and Command-click opens one. A footnote[^1] is a mark in the text and a line at the end.

[^1]: Footnotes are collected at the foot of the preview and of an exported page.

## Tables

Tables stay as source so you can see the pipes line up, and the Table menu does the bookkeeping: insert a table of a chosen size, add or delete rows and columns, set a column's alignment. Inside a table Tab moves to the next cell (and adds a row after the last one); the pipes are padded to line up when you leave it.

| Mark       | Means           |
| :--------- | :-------------- |
| `# `       | a heading       |
| `**x**`    | strong          |
| `- [ ] `   | a task          |

## Pictures

Write `![a description](picture.png)` on a line by itself. In Live mode the picture is drawn there; move the caret onto the line and the source returns. Drop an image file onto the window to link it, or paste an image from the clipboard and it is saved beside the document in a folder named after it.

## Focus, syntax and authorship

Three independent aids, all in the View menu:

- **Focus Mode** dims everything except the sentence or paragraph you are writing (Focus Scope chooses which), and keeps the line you are on in the middle of the window, sliding the page as you type. Keep Focused Line Centred, in the same menu and in Settings, turns the centring off.
- **Syntax Highlight** colours the parts of speech: adjectives, nouns, adverbs, verbs and conjunctions, each of which can be switched off. It is for rereading: long runs of one colour are where a draft is flabby.
- **Authorship** keeps track of whose words are whose. Paste text with Edit > Paste As > AI or Reference, or select text and use Mark As, and it is coloured as borrowed. Your own writing stays the plain text colour. The marks are saved at the end of the file in the open Markdown Annotations format other editors read; a file with no borrowed text is never touched. The same Paste As and Mark As are in the context menu, and over borrowed text it also offers Mark This Passage As, which changes the whole passage under the pointer without selecting it. Show Authorship hides the colours without removing the marks.

## Saving and history

There is nothing to remember to save: a document with a file is written two seconds after you stop typing, and when you close it or open another note in its window. File > Save (Command-S) writes at once. A new document you have not saved is kept in the `Drafts` folder of your library when you have one, and asks when you close it when you do not. If another app changes the file you have open, what you had is kept and the file is read again.

Every pause also keeps a snapshot of the text, so nothing you looked at is lost. View > Show History puts the list of them in the side column on the right (the History pane; Command-Control-H again hides the column): pick one to see what changed since, Restore to put it back (Edit > Undo takes the restore back), or Copy to take its text. Snapshots are kept for a day, then one an hour for a week, then one a day; plain files under `~/Library/Application Support/Markdown/history`.

## Notes mode

View > Notes Mode puts a sidebar beside the editor: a folder of notes (and any others you add under Library) as a tree, with search, tags and, under the list, the notes that link to the one you are reading. A click opens a note in the window you are in (the one you were writing is saved first); Command-click opens it in a window of its own. Quick Open finds a note by a few letters of its title or path. Today's Note (File menu) opens a note named for the day, made from a `Daily` template if you have one, and New from Template fills in the date, the time and the title wherever the template has them in double braces, and puts the caret where it says `cursor`. Write `[[Another note]]` to link to a note, `[[Note|a label]]` to show other words, and `#tag` anywhere in the text; Command-click a link to open it (Command-Option-click opens a wikilink's note in a window of its own). Renaming a note that others link to offers to update their links.

## Getting it out

File > Export > PDF writes the preview as a paginated PDF; File > Print prints it. Edit > Copy As puts the selection (or the whole document) on the clipboard as HTML or as rich text that pastes formatted into Mail and Pages.

## Look and feel

Settings (in the app menu) chooses whether the windows reopen at launch and whether quitting asks first, the theme (Light, Dark, Sepia, or System, which follows the Mac), the writing font, its size and the width of the line. The formatting bar along the bottom, the window buttons and the title fade away while you type and return when you move the pointer, open a menu, or stop typing for a couple of seconds.

## Keyboard shortcuts

This table is read from the menus of the running app, so it is always the current one.

{{SHORTCUTS}}
