import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The demo history (`--seed-history`), against a scratch store: never the real one.
final class HistorySeederTests: XCTestCase {
    private var scratch: URL!
    private var service: HistoryService!
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-seed-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        service = HistoryService(directory: scratch.appendingPathComponent("history"))
    }

    override func tearDown() {
        service.flush()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func demoFile(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("History Demo.md")
        try FileManager.default.copyItem(at: repo.appendingPathComponent("examples/History Demo.md"), to: url)
        return url
    }

    private func specs() throws -> [HistorySeeder.Spec] {
        try HistorySeeder.specs(json: repo.appendingPathComponent("scripts/macos/history-demo/history-demo.json"))
    }

    func testVersionsReasonsTimesAndMessagesAreAsSpecified() throws {
        let file = try demoFile(in: scratch.appendingPathComponent("outside"))
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 13 * 3600)
        let out = try HistorySeeder.seed(file: file, specs: try specs(), service: service, library: nil, now: now, calendar: utc)
        XCTAssertEqual(out.recorded.count, 8)
        XCTAssertEqual(out.skipped, 0)
        XCTAssertEqual(out.recorded.map(\.reason), [.draft, .save, .recovered, .save, .close, .restore, .pause, .close])
        XCTAssertEqual(Set(out.recorded.map(\.reason)).count, 6, "every reason the app uses")
        XCTAssertEqual(out.recorded.compactMap(\.message), ["Before the big rewrite", "Budget section brought back", "Ready to build"])
        let days = out.recorded.map { Int(now.timeIntervalSince1970 - Double($0.time)) / 86_400 }
        XCTAssertEqual(days.first, 10)
        XCTAssertEqual(days.last, 0)
        XCTAssertEqual(out.recorded.map(\.time), out.recorded.map(\.time).sorted())
        XCTAssertLessThan(Date(timeIntervalSince1970: TimeInterval(out.recorded.last!.time)), now)
        // The newest version is the file as it is, so opening it shows no change; the first is a whole draft.
        let key = out.key
        XCTAssertEqual(service.textNow(key: key, id: out.recorded.last!.id), try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(service.versionsNow(key: key).count, 8, "the retention rule drops none of them")
        XCTAssertEqual(out.recorded[0].removed, 0)
        XCTAssertGreaterThan(out.recorded[0].added, 20)
    }

    func testTheKeyIsWhatANormalOpenDerives() throws {
        let outside = try demoFile(in: scratch.appendingPathComponent("outside"))
        let a = try HistorySeeder.seed(file: outside, specs: try specs(), service: service, library: nil)
        XCTAssertEqual(a.key, HistoryKey.key(for: outside, library: nil))
        XCTAssertTrue(a.key.hasPrefix("file:"))

        let libDir = DocumentFileAccess.canonical(scratch).appendingPathComponent("lib")
        let inside = try demoFile(in: libDir.appendingPathComponent("notes"))
        let library = LibraryController()
        library.setRoots([LibraryRootInfo(id: "lib", url: libDir)])
        let b = try HistorySeeder.seed(file: inside, specs: try specs(), service: service, library: library)
        XCTAssertEqual(b.key, "note:lib/notes/History Demo.md")
        XCTAssertEqual(b.key, HistoryKey.key(for: inside, library: library))
        XCTAssertEqual(service.versionsNow(key: b.key).count, 8)
    }

    func testSeedingAgainRecordsNothing() throws {
        let file = try demoFile(in: scratch.appendingPathComponent("outside"))
        let first = try HistorySeeder.seed(file: file, specs: try specs(), service: service, library: nil)
        let before = service.versionsNow(key: first.key)
        // Later, so every time differs from the first run's.
        let again = try HistorySeeder.seed(file: file, specs: try specs(), service: service, library: nil,
                                           now: Date().addingTimeInterval(3 * 86_400))
        XCTAssertTrue(again.recorded.isEmpty)
        XCTAssertEqual(again.skipped, 8)
        XCTAssertEqual(service.versionsNow(key: first.key), before)
    }

    func testBadInputIsAnErrorNotAWrite() throws {
        let file = try demoFile(in: scratch.appendingPathComponent("outside"))
        var bad = try specs()
        bad[0].reason = "nap"
        XCTAssertThrowsError(try HistorySeeder.seed(file: file, specs: bad, service: service, library: nil))
        XCTAssertThrowsError(try HistorySeeder.specs(json: scratch.appendingPathComponent("missing.json")))
        XCTAssertEqual(HistorySeeder.requested(arguments: ["Markdown", "--seed-history", "/a.md", "--seed-versions", "/v.json"])?.json.path, "/v.json")
        XCTAssertNil(HistorySeeder.requested(arguments: ["Markdown"]))
    }
}
