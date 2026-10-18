import Foundation

/// A note's text as the API shows it — LF only — together with the way back to the bytes on disk.
///
/// The API always hands out LF, so an agent never has to reproduce a `\r` to match a passage. But a
/// note authored on Windows keeps its CRLF on disk, and the byte-for-byte rule says a modify must
/// not rewrite the whole file's line endings as a side effect. So a modify matches against the LF
/// text and splices into the original: every untouched stretch keeps its CRLF, and only the replaced
/// passage takes the request's text.
///
/// Counted in Unicode scalars, not `Character`s: Swift reads `\r\n` as one `Character`, which is the
/// exact unit this type has to take apart.
public struct LineEndingMap: Sendable {
    public let raw: [Unicode.Scalar]
    public let lf: [Unicode.Scalar]
    /// `rawIndex[i]` is where `lf[i]` came from in `raw`; one extra entry maps the end.
    private let rawIndex: [Int]

    public init(raw text: String) {
        let raw = Array(text.unicodeScalars)
        var lf: [Unicode.Scalar] = []
        var rawIndex: [Int] = []
        lf.reserveCapacity(raw.count)
        rawIndex.reserveCapacity(raw.count + 1)
        var i = 0
        while i < raw.count {
            rawIndex.append(i)
            if raw[i] == "\r" {
                lf.append("\n")
                // CRLF becomes one LF; a lone CR (classic Mac) becomes one LF too, as the editor reads it.
                i += (i + 1 < raw.count && raw[i + 1] == "\n") ? 2 : 1
            } else {
                lf.append(raw[i])
                i += 1
            }
        }
        rawIndex.append(raw.count)
        self.raw = raw
        self.lf = lf
        self.rawIndex = rawIndex
    }

    public var lfText: String { Self.string(lf) }

    public var hasCarriageReturns: Bool { raw.count != lf.count || raw.contains("\r") }

    /// The stretch of `raw` that an LF range covers. A range ending just before a converted line
    /// break stops before its `\r`, so the CRLF after a replaced line survives intact.
    public func rawRange(_ range: Range<Int>) -> Range<Int> {
        rawIndex[range.lowerBound]..<rawIndex[range.upperBound]
    }

    public static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// LF-only, for comparing what an agent sent with what it was shown.
    public static func normalize(_ text: String) -> String {
        LineEndingMap(raw: text).lfText
    }
}
