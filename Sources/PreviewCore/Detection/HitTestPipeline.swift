import ApplicationServices
import CoreGraphics
import Foundation

public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    public static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func promptScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}

/// Terminals we act on, and how to read their text.
public enum TerminalKind: Sendable {
    case accessibilityFirst   // Terminal.app, iTerm2
    case ocrOnly              // Zed: GPUI exposes no terminal text through AX

    public static func forBundleID(_ id: String?) -> TerminalKind? {
        switch id {
        case "com.apple.Terminal", "com.googlecode.iterm2": return .accessibilityFirst
        case "dev.zed.Zed", "dev.zed.Zed-Preview", "com.mitchellh.ghostty": return .ocrOnly
        default: return nil
        }
    }
}

public enum HitTestPipeline {
    public struct Outcome: Sendable {
        public let hit: ReferenceHit?
        public let note: String
    }

    /// Finds an `[Image #N]` under `point` (global top-left coordinates) in a supported terminal.
    public static func hitTest(at point: CGPoint, appPID: pid_t, bundleID: String?) async -> Outcome {
        guard let kind = TerminalKind.forBundleID(bundleID) else {
            return Outcome(hit: nil, note: "unsupported app \(bundleID ?? "?")")
        }
        var note = ""
        if kind == .accessibilityFirst {
            guard Permissions.accessibility else { return Outcome(hit: nil, note: "accessibility not granted") }
            switch AXHitTester.hitTest(at: point, expectedPID: appPID) {
            case .hit(let hit): return Outcome(hit: hit, note: "ax")
            case .miss: return Outcome(hit: nil, note: "ax miss")
            case .unsupported(let why): note = "ax unsupported: \(why); "
            }
        }
        guard Permissions.screenRecording else {
            return Outcome(hit: nil, note: note + "screen recording not granted")
        }
        do {
            let result = try await OCRHitTester.hitTest(at: point)
            let ms = Int(result.elapsed * 1000)
            return Outcome(hit: result.hit, note: note + "ocr \(ms)ms")
        } catch {
            return Outcome(hit: nil, note: note + "ocr failed: \(error.localizedDescription)")
        }
    }
}
