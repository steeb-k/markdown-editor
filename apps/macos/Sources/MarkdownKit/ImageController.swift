import AppKit
import ImageIO

/// Loads, decodes and caches the images Live mode shows (PLAN 3.4). Everything slow happens off
/// the main thread: reading the file (through `DocumentFileAccess`) or fetching the URL,
/// decoding, and downsampling to the size the layout will use. The main thread only asks what
/// there is to draw right now (`entry(for:)`), which also starts a load when there is nothing
/// yet, and is told when something arrived (`onUpdate`).
///
/// A broken image (missing file, not an image, no network) is a quiet placeholder, never an
/// alert; it is retried only after a while.
public final class ImageController {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    /// What to draw for one destination at one size.
    public struct Entry {
        public var phase: Phase
        /// The image, downsampled to at least the size asked for (nil while loading or broken).
        public var image: CGImage?
        /// The size to reserve in the layout, in points: the image fitted to the budget, or the
        /// placeholder's size.
        public var size: CGSize
    }

    /// The room an image may take: the column width and a cap on its height, in points.
    public struct Budget: Equatable {
        public var width: CGFloat
        public var maxHeight: CGFloat
        public init(width: CGFloat, maxHeight: CGFloat) { self.width = width; self.maxHeight = maxHeight }
    }

    public static let placeholderHeight: CGFloat = 64
    public static let maxRemoteBytes = 40_000_000
    /// How long a failure is remembered before the next request tries again.
    public static let retryInterval: TimeInterval = 20

    /// The folder relative paths resolve against; nil for a document that was never saved.
    public var documentURL: () -> URL? = { nil }
    /// Called on the main thread when an image has been loaded (or failed), with its URL.
    public var onUpdate: ((URL) -> Void)?
    /// Instrumentation (tests): decodes run, and whether the last one ran off the main thread.
    public private(set) var decodeCount = 0
    public private(set) var lastDecodeWasOffMain = false
    public private(set) var requests = 0
    /// True while any load is in flight.
    public var isLoading: Bool { !inFlight.isEmpty }

    private struct Cached {
        var image: CGImage?
        /// The picture's size in points (its pixels, scaled by the resolution the file declares).
        var natural: CGSize
        /// ... and in pixels.
        var naturalPixels: CGSize
        var pixelWidth: Int
        var modified: Date?
        var failedAt: Date?
    }

    private struct Pending: Hashable { var url: URL; var pixelWidth: Int }
    /// What a load decodes for: the budget and the screen scale it was asked at.
    private struct Target { var budget: Budget; var scale: CGFloat }

    // Main thread only:
    private var cache: [URL: Cached] = [:]
    private var inFlight: Set<Pending> = []
    private let queue = OperationQueue()
    private let session: URLSession
    private let lock = NSLock()
    private var counters = (decodes: 0, offMain: true)

    public init() {
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        queue.name = "markdown.images"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: resolving

    /// Where `destination` (as written in the Markdown) points: an `http(s)` or `file` URL, an
    /// absolute path, or a path relative to the document. Nil when it cannot be resolved (a
    /// relative path in a document that was never saved, or an unsupported scheme).
    public func resolve(_ destination: String) -> URL? {
        // The rule the preview follows too (DocumentFileAccess decides for both).
        let doc = documentURL()
        guard let url = DocumentFileAccess.pictureURL(for: destination, documentURL: doc) else { return nil }
        if url.isFileURL, !DocumentFileAccess.mayRead(url, documentURL: doc) { return nil }
        return url
    }

    // MARK: asking

    /// What to draw for `destination` within `budget` on a screen of `scale`. Starts a load
    /// when the image is not cached (or only cached smaller than now needed). Main thread.
    public func entry(for destination: String, budget: Budget, scale: CGFloat) -> Entry {
        requests += 1
        guard let url = resolve(destination) else {
            return Entry(phase: .failed, image: nil, size: Self.placeholderSize(budget))
        }
        let c = cache[url]
        if let c, c.failedAt == nil, let image = c.image {
            let size = Self.fit(c.natural, in: budget)
            let wanted = Int((size.width * scale).rounded(.up))
            // Cached smaller than this layout needs (the window got wider): decode again, and
            // keep drawing what there is meanwhile.
            if c.pixelWidth < wanted - 1, c.pixelWidth < Int(c.naturalPixels.width) {
                load(url, pixelWidth: wanted, target: Target(budget: budget, scale: scale))
            }
            return Entry(phase: .loaded, image: image, size: size)
        }
        if let c, let failedAt = c.failedAt {
            if Date().timeIntervalSince(failedAt) > Self.retryInterval {
                load(url, pixelWidth: Int((budget.width * scale).rounded(.up)), target: Target(budget: budget, scale: scale))
            }
            return Entry(phase: .failed, image: nil, size: Self.placeholderSize(budget))
        }
        load(url, pixelWidth: Int((budget.width * scale).rounded(.up)), target: Target(budget: budget, scale: scale))
        return Entry(phase: .loading, image: nil, size: Self.placeholderSize(budget))
    }

    /// The size an image of `natural` points takes in `budget`: never enlarged, never wider
    /// than the column, never taller than the cap.
    public static func fit(_ natural: CGSize, in budget: Budget) -> CGSize {
        guard natural.width > 0, natural.height > 0, budget.width > 0 else { return placeholderSize(budget) }
        let k = min(1, budget.width / natural.width, max(1, budget.maxHeight) / natural.height)
        return CGSize(width: (natural.width * k).rounded(), height: max(1, (natural.height * k).rounded()))
    }

    public static func placeholderSize(_ budget: Budget) -> CGSize {
        CGSize(width: min(budget.width, 360), height: min(placeholderHeight, max(24, budget.maxHeight)))
    }

    /// Forgets everything cached (tests, memory pressure).
    public func removeAll() { cache.removeAll() }

    /// Checks every cached local file's modification date off the main thread and reloads the
    /// ones that changed (the window became key again after another app edited them).
    public func revalidate() {
        let snapshot = cache.filter { $0.key.isFileURL }.map { ($0.key, $0.value.modified, $0.value.pixelWidth, $0.value.naturalPixels) }
        guard !snapshot.isEmpty else { return }
        queue.addOperation { [weak self] in
            for (url, modified, pixelWidth, natural) in snapshot {
                let now = DocumentFileAccess.modificationDate(of: url)
                if now != modified {
                    // Decode again for what was cached: its width, at the aspect it had.
                    let budget = Budget(width: max(1, CGFloat(pixelWidth)), maxHeight: natural.width > 0 ? CGFloat(pixelWidth) * natural.height / natural.width + 1 : CGFloat(pixelWidth))
                    DispatchQueue.main.async { self?.load(url, pixelWidth: max(pixelWidth, 1), target: Target(budget: budget, scale: 1), force: true) }
                }
            }
        }
    }

    /// Forgets failures (the document was saved: relative paths may resolve now).
    public func forgetFailures() {
        cache = cache.filter { $0.value.failedAt == nil }
    }

    // MARK: loading

    private func load(_ url: URL, pixelWidth: Int, target: Target, force: Bool = false) {
        let pending = Pending(url: url, pixelWidth: pixelWidth)
        guard !inFlight.contains(pending) else { return }
        // One load per URL at a time is enough: a second size waits for the first.
        if !force, inFlight.contains(where: { $0.url == url }) { return }
        inFlight.insert(pending)
        queue.addOperation { [weak self] in
            guard let self else { return }
            let result = self.fetchAndDecode(url, target: target)
            DispatchQueue.main.async {
                self.inFlight.remove(pending)
                switch result {
                case .some(let r):
                    self.cache[url] = Cached(image: r.image, natural: r.natural, naturalPixels: r.naturalPixels, pixelWidth: r.pixelWidth, modified: r.modified, failedAt: nil)
                case .none:
                    self.cache[url] = Cached(image: nil, natural: .zero, naturalPixels: .zero, pixelWidth: 0, modified: nil, failedAt: Date())
                }
                self.onUpdate?(url)
            }
        }
    }

    private struct Decoded { var image: CGImage; var natural: CGSize; var naturalPixels: CGSize; var pixelWidth: Int; var modified: Date? }

    /// Runs on the image queue.
    private func fetchAndDecode(_ url: URL, target: Target) -> Decoded? {
        assert(!Thread.isMainThread)
        var data: Data
        var modified: Date?
        if url.isFileURL {
            guard let d = try? DocumentFileAccess.read(url) else { return nil }
            data = d
            modified = DocumentFileAccess.modificationDate(of: url)
        } else if url.scheme?.lowercased() == "data" {
            // Inline: no file and no network.
            guard let d = try? Data(contentsOf: url), d.count <= Self.maxRemoteBytes else { return nil }
            data = d
        } else {
            guard let (d, date) = fetchRemote(url) else { return nil }
            data = d
            modified = date
        }
        guard let decoded = Self.decode(data, fitting: target.budget, scale: target.scale) else { return nil }
        lock.lock()
        counters.decodes += 1
        counters.offMain = counters.offMain && !Thread.isMainThread
        let (n, off) = counters
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.decodeCount = n; self?.lastDecodeWasOffMain = off }
        return Decoded(image: decoded.image, natural: decoded.natural, naturalPixels: decoded.pixels, pixelWidth: decoded.image.width, modified: modified)
    }

    private func fetchRemote(_ url: URL) -> (Data, Date?)? {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data, Date?)?
        let task = session.dataTask(with: url) { data, response, _ in
            defer { sem.signal() }
            guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count <= Self.maxRemoteBytes else { return }
            let last = (http.value(forHTTPHeaderField: "Last-Modified")).flatMap { Self.httpDate.date(from: $0) }
            out = (data, last)
        }
        task.resume()
        if sem.wait(timeout: .now() + 35) == .timedOut { task.cancel(); return nil }
        return out
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Decodes `data` for the room it will take: fitted to `budget` (never enlarged) at `scale`
    /// pixels per point, orientation applied. `natural` is the picture's size in points (see
    /// `sizes(of:)`), `pixels` its size in pixels.
    public static func decode(_ data: Data, fitting budget: Budget, scale: CGFloat) -> (image: CGImage, natural: CGSize, pixels: CGSize)? {
        guard let sizes = naturalSizes(of: data) else { return nil }
        let size = fit(sizes.points, in: budget)
        return decode(data, maxPixelWidth: Int((size.width * scale).rounded(.up)))
    }

    /// How big a picture is: in pixels, and in points. A file that declares its resolution is
    /// drawn at the size it declares (a retina screenshot is 144 dpi: its points are half its
    /// pixels, as Preview and Finder show it); one that does not, or says 72, is a point per pixel.
    /// Orientation is applied.
    public static func sizes(of src: CGImageSource) -> (pixels: CGSize, points: CGSize)? {
        guard CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0
        else { return nil }
        // Only a believable resolution counts (0 and 1 are what some writers put for "unknown").
        func factor(_ key: CFString) -> Double {
            guard let dpi = (props[key] as? NSNumber)?.doubleValue, dpi >= 24, dpi <= 2400 else { return 1 }
            return 72 / dpi
        }
        var pixels = CGSize(width: w, height: h)
        var points = CGSize(width: w * factor(kCGImagePropertyDPIWidth), height: h * factor(kCGImagePropertyDPIHeight))
        if ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 {
            pixels = CGSize(width: pixels.height, height: pixels.width)
            points = CGSize(width: points.height, height: points.width)
        }
        return (pixels, points)
    }

    static func naturalSizes(of data: Data) -> (pixels: CGSize, points: CGSize)? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
        return sizes(of: src)
    }

    /// The picture's size in points (see `sizes(of:)`).
    static func naturalSize(of data: Data) -> CGSize? { naturalSizes(of: data)?.points }

    /// Decodes `data`, downsampled so the result is at most `maxPixelWidth` wide (and never
    /// upscaled), orientation applied. `natural` is the full size in points, `pixels` in pixels.
    public static func decode(_ data: Data, maxPixelWidth: Int) -> (image: CGImage, natural: CGSize, pixels: CGSize)? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              let sizes = sizes(of: src) else { return nil }
        let pixels = sizes.pixels
        let target = max(1, min(Int(pixels.width), maxPixelWidth))
        // The longest side bounds the thumbnail: scale it so the width comes out at `target`.
        let longest = Double(max(pixels.width, pixels.height)) * Double(target) / Double(pixels.width)
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded(.up)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary) else { return nil }
        return (image, sizes.points, pixels)
    }
}
