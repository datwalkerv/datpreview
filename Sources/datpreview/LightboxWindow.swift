import AppKit

/// Full-screen dimmed viewer. Esc, ⌘W or a click outside the image closes it; pinch, ⌘+/⌘- or
/// double-click zoom; scrolling pans while zoomed. Focus goes back to the previous app on close.
final class LightboxWindow: NSPanel {
    var onClose: (() -> Void)?

    private let scrollView = NSScrollView()
    private let imageView = RoundedImageView()
    private let dim = DimView()
    private var fitSize = NSSize.zero
    private weak var previousApp: NSRunningApplication?
    private var closing = false

    init(image: NSImage, on screen: NSScreen, returnTo app: NSRunningApplication?) {
        previousApp = app
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        dim.frame = root.bounds
        dim.autoresizingMask = [.width, .height]
        dim.onClick = { [weak self] in self?.close() }
        root.addSubview(dim)

        // Image size is in pixels (see ImageLoader). Show one pixel per point at most — comfortable
        // for both retina screenshots and small crops — and fit inside 90% of the visible area.
        let visible = screen.visibleFrame
        let k = min(1, visible.width * 0.9 / image.size.width, visible.height * 0.9 / image.size.height)
        fitSize = NSSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())

        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: fitSize)
        imageView.wantsLayer = true
        imageView.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 24
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            return s
        }()

        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.contentView = CenteringClipView()
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 8
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        root.addSubview(scrollView)
        (scrollView.contentView as! CenteringClipView).onBackgroundClick = { [weak self] in self?.close() }

        contentView = root
        imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleZoom(_:))).configured {
            $0.numberOfClicksRequired = 2
        })
    }

    override var canBecomeKey: Bool { true }

    func present() {
        alphaValue = 0
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
    }

    override func close() {
        guard !closing else { return }
        closing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.previousApp?.activate()
            self.onClose?()
        })
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers ?? "", cmd) {
        case ("\u{1b}", _), ("w", true), (" ", false): close()
        case ("=", true), ("+", true): zoom(by: 1.5, at: nil)
        case ("-", true): zoom(by: 1 / 1.5, at: nil)
        case ("0", true): scrollView.animator().magnification = 1
        default: super.keyDown(with: event)
        }
    }

    @objc private func toggleZoom(_ g: NSClickGestureRecognizer) {
        if scrollView.magnification > 1.01 {
            scrollView.animator().magnification = 1
        } else {
            zoom(by: 2.5, at: g.location(in: imageView))
        }
    }

    private func zoom(by factor: CGFloat, at point: NSPoint?) {
        let target = min(scrollView.maxMagnification, max(1, scrollView.magnification * factor))
        let center = point ?? NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        scrollView.animator().setMagnification(target, centeredAt: center)
    }
}

private final class DimView: NSView {
    var onClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        dirtyRect.fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Keeps a smaller-than-viewport document centered, and reports clicks on the empty margin.
private final class CenteringClipView: NSClipView {
    var onBackgroundClick: (() -> Void)?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }

    override func mouseDown(with event: NSEvent) {
        let p = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        if let doc = documentView, !doc.bounds.contains(p) { onBackgroundClick?() } else { super.mouseDown(with: event) }
    }
}

private extension NSClickGestureRecognizer {
    func configured(_ body: (NSClickGestureRecognizer) -> Void) -> Self { body(self); return self }
}
