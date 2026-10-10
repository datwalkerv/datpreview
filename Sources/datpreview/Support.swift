import AppKit
import PreviewCore

// MARK: - Coordinates

/// AX/CG use a top-left origin on the primary display; AppKit uses bottom-left.
enum ScreenSpace {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func topLeft(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func screen(containing p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}

/// The app owning the topmost normal window under a point (works for unfocused windows too).
/// Owner pid/bounds need no permission; only window titles do.
enum WindowOwner {
    static func app(at topLeftPoint: CGPoint) -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(topLeftPoint) else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }
}

// MARK: - Settings

enum Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    enum HoverDelay: Double, CaseIterable {
        case quick = 0.05, normal = 0.18, relaxed = 0.4
        var title: String {
            switch self { case .quick: "Quick"; case .normal: "Normal"; case .relaxed: "Relaxed" }
        }
    }
    static var hoverDelay: HoverDelay {
        get { HoverDelay(rawValue: defaults.double(forKey: "hoverDelay")) ?? .quick }
        set { defaults.set(newValue.rawValue, forKey: "hoverDelay") }
    }

    enum PreviewSize: Double, CaseIterable {
        case small = 200, medium = 280, large = 380
        var title: String {
            switch self { case .small: "Small"; case .medium: "Medium"; case .large: "Large" }
        }
    }
    static var previewSize: PreviewSize {
        get { PreviewSize(rawValue: defaults.double(forKey: "previewSize")) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "previewSize") }
    }

    static var onboardingShown: Bool {
        get { defaults.bool(forKey: "onboardingShown") }
        set { defaults.set(newValue, forKey: "onboardingShown") }
    }
}

// MARK: - Image loading

/// What a hover resolved to: an image, or a reason it can't be shown.
enum PreviewContent {
    case image(NSImage, title: String)
    case message(String, detail: String)
}

final class ImageLoader: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 24 }

    func content(for result: ResolveResult, number: Int) -> PreviewContent {
        switch result {
        case .noClaudeSession:
            return .message("Image #\(number)", detail: "No Claude Code session found in this window")
        case .notInTranscript:
            return .message("Image #\(number)", detail: "Image not found for this session")
        case let .found(record, _):
            let key = "\(record.sessionID)#\(record.number)" as NSString
            if let image = cache.object(forKey: key) { return .image(image, title: title(record, image)) }
            do {
                let data = try TranscriptIndex.loadData(for: record)
                guard let image = NSImage(data: data) else {
                    return .message("Image #\(number)", detail: "Unsupported image format")
                }
                // Size the image in pixels-as-points so layout math is simple and consistent.
                if let rep = image.representations.first, rep.pixelsWide > 0 {
                    image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
                cache.setObject(image, forKey: key)
                return .image(image, title: title(record, image))
            } catch ImageLoadError.expired {
                return .message("Image #\(number)", detail: "No longer available — Claude Code cleaned up its temp file")
            } catch {
                return .message("Image #\(number)", detail: "Couldn’t read the image from the transcript")
            }
        }
    }

    private func title(_ record: ImageRecord, _ image: NSImage) -> String {
        "Image #\(record.number) · \(Int(image.size.width))×\(Int(image.size.height))"
    }
}
