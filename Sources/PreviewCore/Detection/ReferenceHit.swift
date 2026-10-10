import CoreGraphics
import Foundation

/// An `[Image #N]` found under the pointer.
public struct ReferenceHit: Sendable, Equatable {
    public let number: Int
    /// Screen rect of the reference, global coordinates with a top-left origin (CG / AX space).
    public let rect: CGRect
    /// The surrounding on-screen line, used to disambiguate sessions.
    public let lineText: String
    public let method: Method

    public enum Method: String, Sendable { case accessibility, ocr }
}

public enum ReferenceParser {
    public struct Match: Equatable {
        public let number: Int
        /// UTF-16 range inside the searched string.
        public let range: NSRange
    }

    /// Exact form as Claude Code prints it.
    public static func strictMatches(in text: String) -> [Match] {
        matches(in: text, pattern: #"\[Image #(\d+)\]"#)
    }

    /// Tolerates common OCR misreads: `#` → `H`/`≠`/`*`, brackets → `(`/`|`/`{`/`L`, a bracket
    /// clipped by the crop edge, missing spaces. The closing bracket is never part of the number.
    public static func ocrMatches(in text: String) -> [Match] {
        matches(in: text, pattern: #"[\[(|{lLI]?\s*[Il1]mage\s*[#H≠*]\s*(\d{1,4})(?!\d)\s*[\])|}]?"#)
    }

    private static func matches(in text: String, pattern: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let n = Int(ns.substring(with: m.range(at: 1))) else { return nil }
            return Match(number: n, range: m.range)
        }
    }
}
