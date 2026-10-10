import AppKit

/// The hover tooltip: a non-activating floating panel with a rounded thumbnail and a caption.
final class PreviewPanel: NSPanel {
    var onClick: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let imageView = RoundedImageView()
    private let caption = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let symbol = NSImageView()

    private static let padding: CGFloat = 6
    private static let captionHeight: CGFloat = 18
    private static let cornerRadius: CGFloat = 12

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        contentView = effect

        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        symbol.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        symbol.contentTintColor = .tertiaryLabelColor

        for v in [imageView, caption, detail, symbol] as [NSView] { effect.addSubview(v) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Shows the panel next to `anchor` (AppKit screen coordinates).
    func show(_ content: PreviewContent, maxEdge: CGFloat, anchor: NSRect) {
        let size: NSSize
        switch content {
        case let .image(image, title):
            imageView.isHidden = false; caption.isHidden = false
            detail.isHidden = true; symbol.isHidden = true
            imageView.image = image
            caption.stringValue = title
            let thumb = Self.fit(image.size, maxEdge: maxEdge)
            let p = Self.padding
            size = NSSize(width: max(thumb.width, 140) + p * 2, height: thumb.height + p * 2 + Self.captionHeight)
            imageView.frame = NSRect(x: (size.width - thumb.width) / 2, y: p + Self.captionHeight,
                                     width: thumb.width, height: thumb.height)
            caption.frame = NSRect(x: p, y: 3, width: size.width - p * 2, height: 14)
        case let .message(title, text):
            imageView.isHidden = true; caption.isHidden = false
            detail.isHidden = false; symbol.isHidden = false
            symbol.image = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil)
            caption.stringValue = title
            detail.stringValue = text
            size = NSSize(width: 220, height: 104)
            symbol.frame = NSRect(x: 0, y: 66, width: size.width, height: 28)
            caption.frame = NSRect(x: 10, y: 48, width: size.width - 20, height: 14)
            detail.frame = NSRect(x: 12, y: 8, width: size.width - 24, height: 36)
        }

        setFrame(Self.place(size, near: anchor), display: true)
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }

    static func fit(_ size: NSSize, maxEdge: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: maxEdge, height: maxEdge) }
        let scale = min(1, maxEdge / max(size.width, size.height))
        return NSSize(width: max(24, (size.width * scale).rounded()), height: max(24, (size.height * scale).rounded()))
    }

    /// Below the reference, left-aligned with it; flips above when there's no room; stays on screen.
    static func place(_ size: NSSize, near anchor: NSRect) -> NSRect {
        let gap: CGFloat = 6
        let visible = ScreenSpace.screen(containing: NSPoint(x: anchor.midX, y: anchor.midY))?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
        if origin.y < visible.minY { origin.y = anchor.maxY + gap }
        if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        return NSRect(origin: origin, size: size)
    }
}

/// Image view that draws with rounded corners.
final class RoundedImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
