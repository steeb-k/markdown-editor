#if DEBUG || UI_SCRIPT
import AppKit
import PDFKit

/// Looks into a PDF the app wrote: pages, selectable text, pictures, what a page looks like.
/// For tests and UI scripts; not part of a release build.
enum PDFInspector {
    static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

    /// The text PDFKit can select (the whole document).
    static func text(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }

    static func pageText(_ url: URL, page: Int) -> String { PDFDocument(url: url)?.page(at: page)?.string ?? "" }

    /// Pictures embedded in the document (image XObjects, in the pages' resources and the forms
    /// they use), counted per use site.
    static func imageCount(_ url: URL) -> Int {
        guard let doc = CGPDFDocument(url as CFURL) else { return 0 }
        var count = 0
        for i in 1...max(1, doc.numberOfPages) {
            guard i <= doc.numberOfPages, let page = doc.page(at: i), let dict = page.dictionary else { continue }
            count += images(inResourcesOf: dict, depth: 0)
        }
        return count
    }

    private static func images(inResourcesOf dict: CGPDFDictionaryRef, depth: Int) -> Int {
        var resources: CGPDFDictionaryRef?
        guard depth < 6, CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return 0 }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return 0 }
        final class Box { var images = 0; var forms: [CGPDFDictionaryRef] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(sd, "Subtype", &subtype), let subtype {
                let b = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
                switch String(cString: subtype) {
                case "Image": b.images += 1
                case "Form": b.forms.append(sd)
                default: break
                }
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.images + box.forms.reduce(0) { $0 + images(inResourcesOf: $1, depth: depth + 1) }
    }

    /// Renders page `index` at 1x and returns the pixel at `(x, y)` from the top left, sRGB 0...1.
    static func pixel(_ url: URL, page index: Int, x: Int, y: Int) -> (r: Double, g: Double, b: Double)? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        let size = page.bounds(for: .mediaBox).size
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              x < rep.pixelsWide, y < rep.pixelsHigh,
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// The darkest pixel's luminance on page `index` (0 black ... 1 white): dark text on a light page is near 0.
    static func darkestLuminance(_ url: URL, page index: Int) -> Double? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        let image = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
        guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
        var darkest = 1.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                darkest = min(darkest, 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent))
            }
        }
        return darkest
    }

    /// The box around all the text on a page, in PDF points from the bottom left.
    static func textBounds(_ url: URL, page index: Int) -> CGRect? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        return page.selection(for: page.bounds(for: .mediaBox))?.bounds(for: page)
    }

    static func mediaBox(_ url: URL, page index: Int) -> CGRect? { PDFDocument(url: url)?.page(at: index)?.bounds(for: .mediaBox) }

    /// The box around everything visibly drawn on a page (pixels darker than near-white), in PDF
    /// points from the bottom left. Unlike `textBounds` it ignores text drawn outside the clip
    /// (WebKit leaves such copies in the margins).
    static func inkBounds(_ url: URL, page index: Int) -> CGRect? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        let size = page.bounds(for: .mediaBox).size
        guard let rep = page.thumbnail(of: size, for: .mediaBox).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
        let sx = size.width / CGFloat(rep.pixelsWide), sy = size.height / CGFloat(rep.pixelsHigh)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.redComponent + c.greenComponent + c.blueComponent < 2.85 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run from the top; PDF points from the bottom.
        return CGRect(x: CGFloat(minX) * sx, y: size.height - CGFloat(maxY + 1) * sy, width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }
}
#endif
