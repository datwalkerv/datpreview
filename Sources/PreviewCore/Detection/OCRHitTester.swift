import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Hit-tests `[Image #N]` by OCR-ing a small screen crop around the pointer.
/// Used for terminals that don't expose text through Accessibility (Zed, Ghostty, …).
/// Requires the Screen Recording permission.
public enum OCRHitTester {
    /// Crop around the pointer, in points. Wide enough to hold the whole reference wherever the
    /// pointer sits on it, tall enough for the pointer's line plus a margin.
    public static var cropSize = CGSize(width: 560, height: 56)

    public struct Result: Sendable {
        public let hit: ReferenceHit?
        public let recognizedLines: [String]
        public let elapsed: TimeInterval
        public let image: CGImage?
    }

    /// The first Vision text request loads its model (~200 ms); do it before the first hover.
    public static func warmUp() {
        let ctx = CGContext(data: nil, width: 64, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
        guard let image = ctx?.makeImage() else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
    }

    /// `point` is in global top-left-origin coordinates.
    public static func hitTest(at point: CGPoint, keepImage: Bool = false) async throws -> Result {
        let start = Date()
        let rect = CGRect(x: point.x - cropSize.width / 2, y: point.y - cropSize.height / 2,
                          width: cropSize.width, height: cropSize.height).integral
        let image = try await SCScreenshotManager.captureImage(in: rect)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])

        var lines: [String] = []
        var found: ReferenceHit?
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            lines.append(text)
            guard found == nil else { continue }
            for match in ReferenceParser.ocrMatches(in: text) {
                guard let swiftRange = Range(match.range, in: text),
                      let box = try? candidate.boundingBox(for: swiftRange)?.boundingBox else { continue }
                // Vision boxes are normalized with a bottom-left origin.
                let screenRect = CGRect(
                    x: rect.minX + box.minX * rect.width,
                    y: rect.minY + (1 - box.maxY) * rect.height,
                    width: box.width * rect.width,
                    height: box.height * rect.height)
                if screenRect.insetBy(dx: -3, dy: -4).contains(point) {
                    found = ReferenceHit(number: match.number, rect: screenRect, lineText: text, method: .ocr)
                    break
                }
            }
        }
        return Result(hit: found, recognizedLines: lines, elapsed: Date().timeIntervalSince(start),
                      image: keepImage ? image : nil)
    }
}
