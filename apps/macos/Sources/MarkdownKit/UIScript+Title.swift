#if DEBUG || UI_SCRIPT
import AppKit

/// The harness's checks of the app's own title (`TitlebarTitleView`).
extension UIScriptRunner {
    /// The editor's pane as the window sees it, in window coordinates: from the sidebar's right edge (or the window's left)
    /// to the right column's left edge (or the window's right).
    func titlePaneRange(_ c: EditorWindowController, _ w: NSWindow) -> (left: CGFloat, right: CGFloat) {
        var left: CGFloat = 0
        var right = w.contentView?.bounds.width ?? w.frame.width
        if let bar = c.sidebar?.view, bar.window != nil { left = bar.convert(bar.bounds, to: nil).maxX }
        if let l = c.columnLeft { right = l }
        return (left, right)
    }

    /// What is wrong with the title's place and text, or nil: it is the window's own name, inside the pane's range and
    /// centred over it, in the title bar's row.
    func titleProblem(_ c: EditorWindowController, _ w: NSWindow) -> String? {
        let tv = c.titleView
        guard tv.superview != nil, !tv.isHidden else { return "no title view showing" }
        guard !w.title.isEmpty, tv.name == w.title else { return "title view says \(tv.name.debugDescription), the window \(w.title.debugDescription)" }
        let f = tv.convert(tv.titleFrame, to: nil)
        let range = titlePaneRange(c, w)
        let bar = w.frame.height - w.contentLayoutRect.height
        if f.minX < range.left - 0.5 || f.maxX > range.right + 0.5 { return "title x \(f.minX) to \(f.maxX) outside the pane \(range.left) to \(range.right)" }
        let off = f.midX - (range.left + range.right) / 2
        if abs(off) > 1.5 { return "title is \(off) pt off the pane's centre" }
        if f.minY < w.frame.height - bar - 0.5 || f.maxY > w.frame.height + 0.5 { return "title y \(f.minY) to \(f.maxY) outside the title bar" }
        return nil
    }

    /// `{"title": {"inPane": true, "text": "name", "edited": false, "noIcon": true, "visible": true, "xRange": [min, max]}}`.
    func titleAssertions(_ t: [String: Any], _ c: EditorWindowController, _ w: NSWindow) {
        let tv = c.titleView
        let f = tv.convert(tv.titleFrame, to: nil)
        let range = titlePaneRange(c, w)
        if t["inPane"] as? Bool == true {
            let problem = titleProblem(c, w)
            check("the title is centred over the editor's pane (\(Int(range.left)) to \(Int(range.right)))", problem == nil, problem ?? "x \(f.minX) to \(f.maxX)")
        }
        if let text = t["text"] as? String { check("title text \(text.debugDescription)", tv.name == text, tv.name.debugDescription) }
        if t["followsDocument"] as? Bool == true {
            // Whatever the document's state is (AppKit's own ceiling for a document that is never left alone may have written
            // it already), the title says the same.
            let edited = c.markdownDocument?.isDocumentEdited ?? false
            check("the title says Edited exactly when the document is edited (\(edited))", tv.edited == edited && (tv.parts.status > 0) == edited, "document \(edited) title \(tv.edited) status width \(tv.parts.status)")
        }
        if let want = t["edited"] as? Bool { check("title shows Edited \(want)", tv.edited == want && (tv.edited == (tv.parts.status > 0)), "edited \(tv.edited) status width \(tv.parts.status)") }
        if t["noIcon"] as? Bool == true {
            let images = tv.subviews.filter { $0 is NSImageView }
            check("the title has no document icon", images.isEmpty, "\(images)")
        }
        if let want = t["visible"] as? Bool {
            check("title visible \(want)", (tv.alphaValue > 0.5) == want, "alpha \(tv.alphaValue)")
        }
        if let r = t["xRange"] as? [NSNumber], r.count == 2 {
            // The title's text lies between these x (points from the window's left edge).
            check("title lies within x \(r[0]) to \(r[1])", f.minX >= CGFloat(truncating: r[0]) - 0.5 && f.maxX <= CGFloat(truncating: r[1]) + 0.5, "x \(f.minX) to \(f.maxX)")
        }
        if let want = t["pane"] as? [NSNumber], want.count == 2 {
            check("the pane runs from x \(want[0]) to \(want[1])", abs(range.left - CGFloat(truncating: want[0])) <= 1.5 && abs(range.right - CGFloat(truncating: want[1])) <= 1.5, "\(range)")
        }
        if let want = t["truncated"] as? Bool {
            let p = tv.parts
            let cut = tv.fullNameWidth > p.name + 0.5
            check("title truncated \(want)", cut == want, "name \(p.name) total \(p.total) room \(tv.availableWidth)")
        }
        if t["systemHidden"] as? Bool == true {
            let showing = SystemTitle.views(in: w).filter { !$0.isHidden }.map { "\(Swift.type(of: $0))" }
            check("AppKit's own title views are hidden", showing.isEmpty, "\(showing)")
        }
    }
}
#endif
