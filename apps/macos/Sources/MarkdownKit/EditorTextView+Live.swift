import AppKit
import MarkdownCore
import UniformTypeIdentifiers

/// Mouse, links, drops and pastes: the parts of Live mode (and of inline images) that are about
/// what the pointer and the pasteboard do. Every Markdown decision is the core's.
extension EditorTextView {
    // MARK: mouse

    /// A point in the view as a point in the text container.
    func containerPoint(_ viewPoint: NSPoint) -> NSPoint {
        NSPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), openLink(at: p) { return }
        if handleCheckboxClick(at: p) { return }
        super.mouseDown(with: event)
    }

    /// A click on a task checkbox toggles it as one undo step and leaves the caret where it was.
    @discardableResult
    func handleCheckboxClick(at viewPoint: NSPoint) -> Bool {
        guard let session, session.viewMode == .live, isEditable, !hasMarkedText(),
              let lm = layoutManager as? EditorLayoutManager, let tc = textContainer,
              let d = lm.checkbox(at: containerPoint(viewPoint), in: tc) else { return false }
        toggleTask(at: d.range.location)
        return true
    }

    /// Flips the task marker at `location` through the core, keeping selection and scroll.
    public func toggleTask(at location: Int) {
        guard let session else { return }
        let u = UInt32(location)
        guard let edit = session.coordinator.sync({ $0.toggleTask(at: u) }) else { return }
        let sel = selectedRange()
        let range = NSRange(location: Int(edit.range.start), length: Int(edit.range.end - edit.range.start))
        undoManager?.beginUndoGrouping()
        breakUndoCoalescing()
        session.isApplyingEdit = true
        if replaceThroughUndo(range: range, with: edit.replacement) {
            undoManager?.setActionName("Toggle Task")
            // Same-length replacement: the selection is unchanged unless AppKit moved it.
            let delta = (edit.replacement as NSString).length - range.length
            let shifted = TextChange(old: range, newLength: range.length + delta)
            let a = RangeMath.shiftPoint(sel.location, through: shifted)
            let b = RangeMath.shiftPoint(NSMaxRange(sel), through: shifted)
            if selectedRange() != NSRange(location: a, length: b - a) { setSelectedRange(NSRange(location: a, length: b - a)) }
        }
        session.isApplyingEdit = false
        undoManager?.endUndoGrouping()
        session.selectionChanged(in: self)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard session?.viewMode == .live, let lm = layoutManager as? EditorLayoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        for frame in lm.checkboxFrames(in: tc, characterRange: visibleCharacterRange()) {
            addCursorRect(frame.insetBy(dx: -5, dy: -5).offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
        }
    }

    /// A double click next to concealed markup selects the word, not the markup beside it.
    public override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        var r = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        guard granularity == .selectByWord, let live = (layoutManager as? EditorLayoutManager)?.live, !live.hidden.isEmpty else { return r }
        while r.length > 1, live.isHidden(r.location) { r.location += 1; r.length -= 1 }
        while r.length > 1, live.isHidden(NSMaxRange(r) - 1) { r.length -= 1 }
        return r
    }

    // MARK: links

    /// The character index under `viewPoint`, if the point is on text (not past a line's end).
    func characterIndex(atViewPoint viewPoint: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else { return nil }
        let p = containerPoint(viewPoint)
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
        guard used.insetBy(dx: -2, dy: 0).contains(p) else { return nil }
        return lm.characterIndexForGlyph(at: g)
    }

    /// The link under the point, resolved by the core.
    func link(atViewPoint viewPoint: NSPoint) -> LinkTarget? {
        guard let session, let i = characterIndex(atViewPoint: viewPoint) else { return nil }
        return session.coordinator.sync { $0.linkAt(offset: UInt32(i)) }
    }

    /// Cmd-click: opens the link under the point (web links in the browser, relative links to
    /// local files with their default app). Returns whether there was one.
    @discardableResult
    func openLink(at viewPoint: NSPoint) -> Bool {
        guard let target = link(atViewPoint: viewPoint) else { return false }
        guard let url = LinkOpener.url(for: target.destination, documentURL: session?.documentURL()) else { return true }
        LinkOpener.open(url)
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateLinkCursor(modifiers: event.modifierFlags)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateLinkCursor(modifiers: event.modifierFlags)
    }

    private func updateLinkCursor(modifiers: NSEvent.ModifierFlags) {
        guard modifiers.contains(.command), let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p), link(atViewPoint: p) != nil { NSCursor.pointingHand.set() }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self && a.userInfo?["markdownLink"] != nil { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["markdownLink": true]))
    }

    // MARK: scrolling

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    private func observeScrolling() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        session?.visibleRangeChanged()
    }

    // MARK: drop and paste

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL] }

    private func droppedFileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditable && !droppedFileURLs(sender.draggingPasteboard).isEmpty ? .copy : super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditable && !droppedFileURLs(sender.draggingPasteboard).isEmpty ? .copy : super.draggingUpdated(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        if handleDrop(sender.draggingPasteboard, at: characterIndexForInsertion(at: point)) { return true }
        return super.performDragOperation(sender)
    }

    /// Files dropped (or pasted): images become `![name](path)`, anything else a link. Several
    /// files go on lines of their own, all as one undo step. Returns false when the pasteboard
    /// holds no files.
    @discardableResult
    public func handleDrop(_ pasteboard: NSPasteboard, at index: Int) -> Bool {
        let urls = droppedFileURLs(pasteboard)
        guard isEditable, !urls.isEmpty, session != nil else { return false }
        insertFiles(urls, at: index)
        return true
    }

    public func insertFiles(_ urls: [URL], at index: Int) {
        guard let session else { return }
        let docURL = session.documentURL()
        let at = min(max(0, index), session.storage.length)
        undoManager?.beginUndoGrouping()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: at, length: 0))
        for (n, url) in urls.enumerated() {
            if n > 0 {
                let end = NSMaxRange(selectedRange())
                _ = replaceThroughUndo(range: NSRange(location: end, length: 0), with: "\n\n")
                setSelectedRange(NSRange(location: end + 2, length: 0))
            }
            let path = DocumentFileAccess.path(of: url, relativeTo: docURL)
            let name = url.deletingPathExtension().lastPathComponent
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            let command: FormatCommand = isImage
                ? .image(destination: path, alt: name)
                : .linkTo(destination: path, text: url.lastPathComponent)
            perform(actionName: isImage ? "Insert Image" : "Insert Link") { $0.format(command: command, selection: $1) }
        }
        undoManager?.setActionName(urls.count == 1 && (UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .image) ?? false) ? "Insert Image" : "Insert Files")
        undoManager?.endUndoGrouping()
    }

    /// Pasting: image data becomes a PNG in `<document>.assets` and an image reference, files
    /// are handled like a drop, anything else is plain text as before.
    public override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if isEditable, session != nil {
            if handleDrop(pb, at: selectedRange().location) { return }
            if pasteboardHasOnlyImage(pb) { pasteImage(from: pb); return }
        }
        pasteAsPlainText(sender)
    }

    func pasteboardHasOnlyImage(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        let textual: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .fileURL, .URL]
        if types.contains(where: textual.contains) { return false }
        return types.contains(.png) || types.contains(.tiff)
    }

    /// Writes the pasteboard's image next to the document and inserts it. An unsaved document
    /// is saved first (the standard save panel); cancelling aborts quietly. `completion` is
    /// called on the main thread with whether an image was inserted.
    public func pasteImage(from pb: NSPasteboard, completion: ((Bool) -> Void)? = nil) {
        guard let session else { completion?(false); return }
        let png: Data? = pb.data(forType: .png)
            ?? pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { completion?(false); return }
        withSavedDocument { [weak self] docURL in
            guard let self, let docURL else { completion?(false); return }
            let assets = docURL.deletingLastPathComponent()
                .appendingPathComponent(docURL.deletingPathExtension().lastPathComponent + ".assets", isDirectory: true)
            DispatchQueue.global(qos: .userInitiated).async {
                var written: URL?
                do {
                    try DocumentFileAccess.createDirectory(assets)
                    let url = DocumentFileAccess.uniqueURL(in: assets, name: "image", ext: "png")
                    try DocumentFileAccess.write(png, to: url)
                    written = url
                } catch {}
                DispatchQueue.main.async {
                    guard let url = written else { completion?(false); return }
                    let path = DocumentFileAccess.path(of: url, relativeTo: session.documentURL())
                    // After an asynchronous gap: its own undo step, whatever the event grouping.
                    self.undoManager?.beginUndoGrouping()
                    self.breakUndoCoalescing()
                    self.perform(actionName: "Paste Image") { $0.format(command: .image(destination: path, alt: "image"), selection: $1) }
                    self.undoManager?.endUndoGrouping()
                    completion?(true)
                }
            }
        }
    }

    /// Runs `body` with the document's URL, saving the document first when it has none.
    private func withSavedDocument(_ body: @escaping (URL?) -> Void) {
        guard let session else { body(nil); return }
        if let url = session.documentURL() { body(url); return }
        guard let save = session.requestSave else { body(nil); return }
        save { ok in body(ok ? session.documentURL() : nil) }
    }
}

/// Where a link destination points on this machine, and opening it.
public enum LinkOpener {
    /// The URL to open for `destination` as written in the Markdown: web and mail links as they
    /// are, a bare `www.` address as http, anything else a file path (absolute, `~/`, or
    /// relative to the document). Nil for in-page anchors and for relative paths in a document
    /// that was never saved.
    public static func url(for destination: String, documentURL: URL?) -> URL? {
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, !d.hasPrefix("#") else { return nil }
        if d.lowercased().hasPrefix("www.") { return URL(string: "http://" + d) }
        if let colon = d.firstIndex(of: ":"), d[..<colon].count > 1,
           d[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
            let url = URL(string: d) ?? URL(string: d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel", "file"].contains(scheme) else { return nil }
            return url
        }
        var path = d.removingPercentEncoding ?? d
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        guard let doc = documentURL else { return nil }
        return URL(fileURLWithPath: path, relativeTo: doc.deletingLastPathComponent()).standardizedFileURL
    }

    /// Test hook: every URL asked to open is recorded here instead of opened.
    nonisolated(unsafe) public static var opened: ((URL) -> Bool)?

    public static func open(_ url: URL) {
        if let hook = opened, hook(url) { return }
        NSWorkspace.shared.open(url)
    }
}
