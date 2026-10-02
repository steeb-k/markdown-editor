import XCTest
import MarkdownCore
@testable import MarkdownKit

final class FFITests: XCTestCase {
    func testDocumentRoundTripWithEmoji() {
        let text = "héllo 🎉 e\u{301} 日本語\r\nnext"
        XCTAssertEqual(Document(text: text).text(), text)
    }

    func testCoreVersion() {
        XCTAssertFalse(coreVersion().isEmpty)
    }

    func testInitialTextGoesThroughCore() {
        XCTAssertTrue(AppDelegate.initialText().contains(coreVersion()))
    }
}
