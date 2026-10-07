import AppKit
import MarkdownCore

extension EditorSession {
    /// Replaces the whole text with `text` as one undoable change (a version of the history coming back). The caret
    /// stays where it was, as far as the new text goes.
    func restoreText(_ text: String, actionName: String) {
        guard let tv = textView, text != storage.string else { return }
        let selection = tv.selectedRange()
        tv.undoManager?.beginUndoGrouping()
        tv.breakUndoCoalescing()
        isApplyingEdit = true
        _ = tv.replaceThroughUndo(range: NSRange(location: 0, length: storage.length), with: text)
        isApplyingEdit = false
        tv.breakUndoCoalescing()
        tv.undoManager?.setActionName(actionName)
        tv.undoManager?.endUndoGrouping()
        let length = storage.length
        tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        selectionChanged(in: tv)
    }

    /// Writes the library's link edits (ranges in this text) into the document, all as one undoable
    /// change: a rename that others link to updates them in the notes that are open. False, with the
    /// text untouched, when an edit does not fit the text.
    @discardableResult
    func applyLinkEdits(_ edits: [LibraryEdit], actionName: String = "Update Links") -> Bool {
        // A text view that takes no typing (an authorship question pending) refuses each replacement: reporting the
        // edits as written would leave the note naming what it named, with nobody told.
        guard let tv = textView, tv.isEditable, !edits.isEmpty else { return false }
        let ordered = edits.sorted { $0.range.start > $1.range.start }
        var last = storage.length
        let text = storage.string as NSString
        for e in ordered {
            let end = Int(e.range.end)
            guard Int(e.range.start) <= end, end <= last else { return false }
            if let original = e.original,
               text.substring(with: NSRange(location: Int(e.range.start), length: end - Int(e.range.start))) != original { return false }
            last = Int(e.range.start)
        }
        let selection = tv.selectedRange()
        tv.undoManager?.beginUndoGrouping()
        tv.breakUndoCoalescing()
        isApplyingEdit = true
        for e in ordered {
            _ = tv.replaceThroughUndo(range: NSRange(location: Int(e.range.start), length: Int(e.range.end - e.range.start)), with: e.replacement)
        }
        isApplyingEdit = false
        tv.breakUndoCoalescing()
        tv.undoManager?.setActionName(actionName)
        tv.undoManager?.endUndoGrouping()
        // The caret stays with the text it was in.
        let moved = ordered.reduce(selection) { sel, e in
            let change = TextChange(old: NSRange(location: Int(e.range.start), length: Int(e.range.end - e.range.start)),
                                    newLength: (e.replacement as NSString).length)
            let a = RangeMath.shiftPoint(sel.location, through: change), b = RangeMath.shiftPoint(NSMaxRange(sel), through: change)
            return NSRange(location: a, length: b - a)
        }
        if moved != tv.selectedRange(), NSMaxRange(moved) <= storage.length { tv.setSelectedRange(moved) }
        selectionChanged(in: tv)
        return true
    }
}
