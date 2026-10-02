import Foundation
import MarkdownCore

public enum LineEnding: Equatable, Sendable {
    case lf, crlf, cr
    /// Both kinds in one file: kept untouched, never normalized.
    case mixed
}

public struct DecodedText: Equatable {
    /// What the editor holds: line endings normalized to `\n` (unless the file mixes them).
    public var text: String
    public var hasBOM: Bool
    public var lineEnding: LineEnding
    /// The file's text as it is on disk (BOM removed, line endings untouched): what the
    /// annotation block's hash covers.
    public var raw: String
}

extension LineEnding {
    /// How the core's annotation block writes (and hashes) line endings for this file.
    var annotationEnding: AnnotationLineEnding {
        switch self {
        case .lf: return .lf
        case .crlf: return .crLf
        case .cr: return .cr
        case .mixed: return .preserve
        }
    }
}

/// Bytes on disk <-> the string the editor holds. A file opened and saved without edits must
/// come out byte-identical, so the BOM and the line endings are remembered, not guessed at
/// save time. A file using one kind of line ending throughout is edited with `\n` and written
/// back with its own; a file mixing them is left exactly as it is.
public enum TextCodec {
    public static func decode(_ data: Data) throws -> DecodedText {
        var body = data
        var hasBOM = false
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            body = data.dropFirst(3)
        }
        if body.contains(0) { throw error("The file contains null bytes, so it is not a text file.") }
        guard let text = String(data: body, encoding: .utf8) else {
            throw error("The file is not valid UTF-8 text.")
        }
        var crlf = 0, lf = 0, cr = 0
        var prev: UInt8 = 0
        for b in body {
            if b == 0x0A { if prev == 0x0D { crlf += 1; cr -= 1 } else { lf += 1 } }
            else if b == 0x0D { cr += 1 }
            prev = b
        }
        let kinds = [crlf > 0, lf > 0, cr > 0].filter { $0 }.count
        let ending: LineEnding
        var normalized = text
        switch (kinds, crlf > 0, cr > 0) {
        case (0, _, _), (1, false, false): ending = .lf
        case (1, true, _):
            ending = .crlf
            normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        case (1, _, true):
            ending = .cr
            normalized = text.replacingOccurrences(of: "\r", with: "\n")
        default: ending = .mixed
        }
        return DecodedText(text: normalized, hasBOM: hasBOM, lineEnding: ending, raw: text)
    }

    /// `text` from a file with `ending` line endings, as the editor holds it.
    public static func normalize(_ text: String, _ ending: LineEnding) -> String {
        switch ending {
        case .crlf: return text.replacingOccurrences(of: "\r\n", with: "\n")
        case .cr: return text.replacingOccurrences(of: "\r", with: "\n")
        case .lf, .mixed: return text
        }
    }

    public static func encode(_ text: String, hasBOM: Bool, lineEnding: LineEnding) -> Data {
        var out = text
        switch lineEnding {
        case .crlf: out = text.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: out = text.replacingOccurrences(of: "\n", with: "\r")
        case .lf, .mixed: break
        }
        var data = Data()
        if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(out.utf8))
        return data
    }

    private static func error(_ reason: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError, userInfo: [
            NSLocalizedDescriptionKey: "The document could not be opened.",
            NSLocalizedFailureReasonErrorKey: reason,
            NSLocalizedRecoverySuggestionErrorKey: "Markdown opens UTF-8 text files only.",
        ])
    }
}
