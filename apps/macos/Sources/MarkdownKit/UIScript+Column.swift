#if DEBUG || UI_SCRIPT
import AppKit

/// The harness's steps and checks for the side column: the menu items that show and hide it, the header's segments, and
/// what the column holds (the outline's and the history's own steps are in `UIScript+Outline` and `UIScript+History`).
extension UIScriptRunner {
    /// `{"column": {"toggle": true}}` is View > Side Column (⌃⌘O), `{"showHistory": true}` View > Show History (⌃⌘H),
    /// `{"segment": "history"}` a click on the header's segment, `{"remember": "name"}` keeps the column's width for
    /// the `widthSameAs` check.
    func columnStep(_ c: [String: Any], then done: @escaping () -> Void) {
        guard let wc = notesController ?? controller else { record(["column": "no window"], ok: false); done(); return }
        if c["toggle"] as? Bool == true {
            _ = NSApp.sendAction(#selector(EditorWindowController.toggleSideColumn(_:)), to: wc, from: nil)
            record(["column": "toggle", "shown": wc.session.columnShown, "pane": wc.session.columnPane.rawValue, "width": wc.columnView?.frame.width ?? 0], ok: true)
        } else if c["showHistory"] as? Bool == true {
            _ = NSApp.sendAction(#selector(EditorWindowController.showHistory(_:)), to: wc, from: nil)
            record(["column": "showHistory", "shown": wc.session.columnShown, "pane": wc.session.columnPane.rawValue, "width": wc.columnView?.frame.width ?? 0], ok: true)
        } else if let name = c["segment"] as? String, let pane = SideColumnPane(rawValue: name) {
            let ok = wc.sideColumn != nil
            if ok { chooseSegment(pane, wc) }
            record(["column": "segment \(name)", "pane": wc.session.columnPane.rawValue, "width": wc.columnView?.frame.width ?? 0], ok: ok)
        } else if let name = c["remember"] as? String {
            remembered[name, default: [:]]["columnWidth"] = wc.columnView?.frame.width ?? 0
            record(["column": "remember \(name)", "width": wc.columnView?.frame.width ?? 0], ok: wc.columnView != nil)
        } else {
            record(["column": c, "error": "unknown step"], ok: false)
        }
        later(0.3, done)
    }

    func columnAssertions(_ a: [String: Any]) {
        guard let wc = notesController ?? controller else { check("column", false, "no window"); return }
        let column = wc.sideColumn
        if let want = a["shown"] as? Bool {
            let shown = column != nil && column?.view.window != nil && wc.paneHost?.superview != nil && wc.session.columnShown
            check("side column shown \(want)", shown == want, "column \(column != nil) flag \(wc.session.columnShown)")
        }
        if let name = a["pane"] as? String, let pane = SideColumnPane(rawValue: name) {
            // The pane's own controller is alive and showing, the other's is not alive at all, and the header's segment says so.
            let alive = (wc.outline != nil) == (pane == .outline) && (wc.history != nil) == (pane == .history)
            let content = column?.view.content
            let hosted = (pane == .outline ? wc.outline?.view : wc.history?.view).map { $0 === content && $0.superview === column?.view } ?? false
            let segment = column?.view.header.selectedSegment
            check("side column shows \(name)", wc.session.columnPane == pane && alive && hosted && segment == SideColumnPane.allCases.firstIndex(of: pane),
                  "session \(wc.session.columnPane) outline \(wc.outline != nil) history \(wc.history != nil) hosted \(hosted) segment \(String(describing: segment))")
        }
        if let want = (a["width"] as? NSNumber)?.doubleValue {
            let w = wc.columnView?.frame.width ?? 0
            check("side column is \(want) wide", abs(Double(w) - want) <= 1.5, "\(w)")
        }
        if let name = a["widthSameAs"] as? String {
            let was = remembered[name]?["columnWidth"], now = wc.columnView?.frame.width
            check("side column width unchanged since \(name)", was != nil && now != nil && abs(was! - now!) < 0.5, "was \(String(describing: was)) now \(String(describing: now))")
        }
        if let name = a["defaultPane"] as? String { check("the default pane is \(name)", Settings.shared.sideColumnPane.rawValue == name, Settings.shared.sideColumnPane.rawValue) }
        if let w = (a["defaultWidth"] as? NSNumber)?.doubleValue { check("the default width is \(w)", abs(Settings.shared.sideColumnWidth - w) <= 1.5, "\(Settings.shared.sideColumnWidth)") }
        if let w = (a["sessionWidth"] as? NSNumber)?.doubleValue { check("this window remembers width \(w)", abs(Double(wc.session.columnWidth) - w) <= 1.5, "\(wc.session.columnWidth)") }
        if a["accessible"] as? Bool == true, let header = column?.view.header {
            let labels = (0..<header.segmentCount).map { header.label(forSegment: $0) ?? "" }
            check("the header is a labelled control with Outline and History", header.accessibilityLabel() == "Side column" && labels == ["Outline", "History"] && header.controlSize == .small,
                  "\(String(describing: header.accessibilityLabel())) \(labels) size \(header.controlSize.rawValue)")
        }
    }
}
#endif
