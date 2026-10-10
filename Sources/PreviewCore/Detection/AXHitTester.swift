import ApplicationServices
import Foundation

/// Hit-tests `[Image #N]` through the Accessibility text APIs (Terminal.app, iTerm2).
public enum AXHitTester {
    public enum Outcome: Sendable {
        case hit(ReferenceHit)
        /// Text is readable here but there's no reference under the pointer.
        case miss
        /// The element under the pointer doesn't expose text ranges; try OCR instead.
        case unsupported(String)
    }

    private static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }()

    /// `point` is in global top-left-origin coordinates.
    public static func hitTest(at point: CGPoint, expectedPID: pid_t?) -> Outcome {
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        guard err == .success, let element else { return .unsupported("no element (\(err.rawValue))") }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let expectedPID, pid != expectedPID { return .unsupported("element belongs to pid \(pid)") }

        var pointValue = point
        guard let axPoint = AXValueCreate(.cgPoint, &pointValue),
              let rangeValue: AXValue = param(element, kAXRangeForPositionParameterizedAttribute, axPoint),
              let charRange = rangeValue.cfRange else {
            return .unsupported("role \(role(of: element)) has no AXRangeForPosition")
        }
        let index = charRange.location
        guard index >= 0 else { return .miss }

        // Prefer the exact line; otherwise read a window around the index.
        var searchRange = CFRange(location: max(0, index - 200), length: 400)
        if let line: NSNumber = param(element, kAXLineForIndexParameterizedAttribute, index as CFNumber),
           let lineRangeValue: AXValue = param(element, kAXRangeForLineParameterizedAttribute, line),
           let lineRange = lineRangeValue.cfRange, lineRange.length > 0 {
            searchRange = lineRange
        }
        guard let text = string(element, range: searchRange) ?? string(element, range: clamp(searchRange, element)) else {
            return .unsupported("AXStringForRange failed")
        }

        for match in ReferenceParser.strictMatches(in: text) {
            let absolute = CFRange(location: searchRange.location + match.range.location, length: match.range.length)
            guard index >= absolute.location, index < absolute.location + absolute.length else { continue }
            var rect = CGRect(origin: point, size: .zero).insetBy(dx: -4, dy: -8)
            var r = absolute
            if let axRange = AXValueCreate(.cfRange, &r),
               let boundsValue: AXValue = param(element, kAXBoundsForRangeParameterizedAttribute, axRange) {
                var b = CGRect.zero
                if AXValueGetValue(boundsValue, .cgRect, &b), b.width > 0 { rect = b }
            }
            let lineText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .hit(ReferenceHit(number: match.number, rect: rect, lineText: lineText, method: .accessibility))
        }
        return .miss
    }

    /// Dumps the role chain under the pointer; used by `refprobe --ax-tree` to see what a terminal exposes.
    public static func describe(at point: CGPoint) -> String {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return "(no element)" }
        var parts: [String] = []
        for _ in 0..<8 {
            var names: CFArray?
            AXUIElementCopyParameterizedAttributeNames(current, &names)
            let params = (names as? [String])?.count ?? 0
            parts.append("\(role(of: current)) [\(params) param attrs]")
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            current = p as! AXUIElement
        }
        return parts.joined(separator: " ← ")
    }

    // MARK: helpers

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String ?? "?"
    }

    private static func param<T>(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value as? T
    }

    private static func string(_ element: AXUIElement, range: CFRange) -> String? {
        var r = range
        guard let axRange = AXValueCreate(.cfRange, &r) else { return nil }
        return param(element, kAXStringForRangeParameterizedAttribute, axRange)
    }

    private static func clamp(_ range: CFRange, _ element: AXUIElement) -> CFRange {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value)
        let total = (value as? NSNumber)?.intValue ?? 0
        let start = min(range.location, max(0, total - 1))
        return CFRange(location: start, length: max(0, min(range.length, total - start)))
    }
}

private extension AXValue {
    var cfRange: CFRange? {
        var r = CFRange()
        return AXValueGetValue(self, .cfRange, &r) ? r : nil
    }
}
