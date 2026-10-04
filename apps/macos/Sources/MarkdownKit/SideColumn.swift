import AppKit

/// What the right-hand column shows: the document's headings, or the history of its versions.
public enum SideColumnPane: String, CaseIterable, Sendable {
    case outline, history

    public var title: String {
        switch self {
        case .outline: return "Outline"
        case .history: return "History"
        }
    }
}

/// The column itself: the title bar's row (a band, as the sidebar has, that drags and zooms the window), under it a
/// segmented control that says which pane is showing and switches, and the pane's own view in the rest of the room.
/// It runs under the title bar like the sidebar. The panes know nothing of the title bar: they start where their room does.
final class SideColumnView: NSView {
    let band = TitlebarBandView()
    let header = NSSegmentedControl(labels: SideColumnPane.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private(set) var content: NSView?
    var style: SidebarStyle { didSet { needsDisplay = true } }

    static let headerHeight: CGFloat = 22
    /// Over and under the control.
    static let headerMargin: CGFloat = 6

    init(style: SidebarStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        header.controlSize = .small
        header.segmentStyle = .rounded
        header.segmentDistribution = .fillEqually
        header.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        header.setAccessibilityLabel("Side column")
        header.setAccessibilityIdentifier("side-column-header")
        for (i, pane) in SideColumnPane.allCases.enumerated() {
            header.setToolTip(pane == .outline ? "The headings of this document" : "The versions of this document", forSegment: i)
        }
        addSubview(band)
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// What the title bar takes from the top (the column runs under it).
    var topInset: CGFloat {
        guard let w = window else { return 28 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }

    var contentTop: CGFloat { topInset + Self.headerMargin + Self.headerHeight + 2 }

    func setContent(_ v: NSView?) {
        guard v !== content else { return }
        content?.removeFromSuperview()
        content = v
        if let v {
            addSubview(v, positioned: .below, relativeTo: band)
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let top = topInset
        band.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        header.frame = NSRect(x: 10, y: top + Self.headerMargin, width: max(0, bounds.width - 20), height: Self.headerHeight)
        // Equal segments that fill the control (the distribution alone left the second one cut off).
        let each = ((header.frame.width - 4) / CGFloat(max(1, header.segmentCount))).rounded(.down)
        for i in 0..<header.segmentCount where header.width(forSegment: i) != each { header.setWidth(each, forSegment: i) }
        let y = contentTop
        content?.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }

    override func draw(_ dirtyRect: NSRect) {
        style.background.setFill()
        bounds.fill()
    }
}

/// The right-hand column of a window: one view with a segmented header (Outline | History) and one content area that holds
/// the outline's view or the history's, whichever is selected. The panes are made when selected and let go of when
/// another is: both are alive only while shown. The width is the window's, and switching never changes it.
@MainActor
final class SideColumnController: NSObject {
    let view: SideColumnView
    private(set) var pane: SideColumnPane
    private(set) var outline: OutlineController?
    private(set) var history: HistoryController?
    /// Made when their pane is selected.
    var makeOutline: (() -> OutlineController)?
    var makeHistory: (() -> HistoryController)?
    /// What happens to a pane as it goes (the history lets go of its service).
    var willDrop: ((SideColumnPane) -> Void)?
    /// The person chose a segment (not a pane set from a menu or the settings).
    var onChoose: ((SideColumnPane) -> Void)?
    /// Instrumentation: how many panes were made.
    private(set) var madePanes = 0

    init(pane: SideColumnPane, style: SidebarStyle) {
        self.pane = pane
        view = SideColumnView(style: style)
        super.init()
        view.header.target = self
        view.header.action = #selector(segmentChosen(_:))
        view.header.selectedSegment = SideColumnPane.allCases.firstIndex(of: pane) ?? 0
    }

    /// The pane shown now is `pane`: its controller exists and its view is in the content area; the other's is gone.
    func show(_ new: SideColumnPane) {
        pane = new
        view.header.selectedSegment = SideColumnPane.allCases.firstIndex(of: new) ?? 0
        switch new {
        case .outline:
            if history != nil { drop(.history) }
            if outline == nil, let make = makeOutline {
                let o = make()
                outline = o
                madePanes += 1
            }
            view.setContent(outline?.view)
        case .history:
            if outline != nil { drop(.outline) }
            if history == nil, let make = makeHistory {
                let h = make()
                history = h
                madePanes += 1
            }
            view.setContent(history?.view)
        }
    }

    private func drop(_ dropped: SideColumnPane) {
        willDrop?(dropped)
        view.setContent(nil)
        switch dropped {
        case .outline: outline = nil
        case .history: history = nil
        }
    }

    /// The column is going away: whatever it shows goes first.
    func tearDown() {
        if outline != nil { drop(.outline) }
        if history != nil { drop(.history) }
    }

    @objc private func segmentChosen(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard i >= 0, i < SideColumnPane.allCases.count else { return }
        let chosen = SideColumnPane.allCases[i]
        onChoose?(chosen)
    }

    func styleChanged(_ style: SidebarStyle) {
        if style != view.style { view.style = style }
    }
}
