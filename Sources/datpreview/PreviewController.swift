import AppKit
import PreviewCore

/// Watches the pointer (passively — events are observed, never consumed), hit-tests for
/// `[Image #N]` once it rests over a supported terminal, and drives the preview and lightbox.
@MainActor
final class PreviewController {
    private let registry = SessionRegistry()
    private lazy var resolver = SessionResolver(registry: registry)
    private let loader = ImageLoader()
    private let panel = PreviewPanel()
    private var lightbox: LightboxWindow?

    private var monitors: [Any] = []
    private var restTimer: Timer?
    private var probeGeneration = 0

    /// What's currently shown: the reference rect (top-left coords) and its content.
    private var current: (hit: ReferenceHit, content: PreviewContent, app: NSRunningApplication)?
    /// Where a probe found nothing; skip re-probing until the pointer leaves this spot.
    private var lastMiss: CGPoint?

    var onStatusChange: ((String) -> Void)?

    init() {
        panel.onClick = { [weak self] in self?.openLightbox() }
    }

    func start() {
        guard monitors.isEmpty else { return }
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .keyDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePreview() }
        }) { monitors.append(m) }
        // Our own panel receives events directly, so watch locally too (to hide when leaving it).
        if let m = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(m) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.hidePreview() } }

        Task.detached(priority: .utility) { OCRHitTester.warmUp() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        restTimer?.invalidate()
        hidePreview()
    }

    // MARK: - Pointer

    private func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        let p = ScreenSpace.topLeft(mouse)

        if let current {
            let stillOnReference = current.hit.rect.insetBy(dx: -4, dy: -4).contains(p)
            let onPanel = panel.isVisible && NSMouseInRect(mouse, panel.frame.insetBy(dx: -2, dy: -2), false)
            if stillOnReference || onPanel { return }
            // Moving from the reference toward the panel crosses the gap; allow that corridor.
            let corridor = ScreenSpace.toAppKit(current.hit.rect).union(panel.frame)
            if panel.isVisible, NSMouseInRect(mouse, corridor, false) { return }
            hidePreview()
        }

        if let miss = lastMiss, hypot(miss.x - p.x, miss.y - p.y) < 3 { return }
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: Settings.hoverDelay.rawValue, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe(at: p) }
        }
    }

    private func probe(at p: CGPoint) {
        guard Settings.enabled, lightbox == nil else { return }
        guard let app = WindowOwner.app(at: p), TerminalKind.forBundleID(app.bundleIdentifier) != nil else { return }

        probeGeneration += 1
        let generation = probeGeneration
        let pid = app.processIdentifier, bundleID = app.bundleIdentifier
        let resolver = self.resolver, loader = self.loader

        Task.detached(priority: .userInitiated) {
            let outcome = await HitTestPipeline.hitTest(at: p, appPID: pid, bundleID: bundleID)
            let content: PreviewContent? = outcome.hit.map { hit in
                let context = TerminalContext(appPID: pid, bundleID: bundleID)
                let result = resolver.resolve(number: hit.number, lineText: hit.lineText, in: context)
                return loader.content(for: result, number: hit.number)
            }
            await MainActor.run { [weak self] in
                guard let self, generation == self.probeGeneration else { return }
                self.onStatusChange?(outcome.note)
                // Ignore results if the pointer has since left the probed spot.
                let now = ScreenSpace.topLeft(NSEvent.mouseLocation)
                guard hypot(now.x - p.x, now.y - p.y) < 6 else { return }
                guard let hit = outcome.hit, let content else { self.lastMiss = p; return }
                self.lastMiss = nil
                self.current = (hit, content, app)
                self.panel.show(content, maxEdge: Settings.previewSize.rawValue, anchor: ScreenSpace.toAppKit(hit.rect))
            }
        }
    }

    private func clicked() {
        guard let current else { return }
        let p = ScreenSpace.topLeft(NSEvent.mouseLocation)
        if current.hit.rect.insetBy(dx: -2, dy: -2).contains(p) {
            openLightbox()
        } else {
            hidePreview()
        }
    }

    private func hidePreview() {
        restTimer?.invalidate()
        probeGeneration += 1
        current = nil
        panel.dismiss()
    }

    // MARK: - Lightbox

    private func openLightbox() {
        guard lightbox == nil, let current, case let .image(image, _) = current.content else { return }
        let anchor = ScreenSpace.toAppKit(current.hit.rect)
        guard let screen = ScreenSpace.screen(containing: NSPoint(x: anchor.midX, y: anchor.midY)) else { return }
        let app = current.app
        hidePreview()
        let window = LightboxWindow(image: image, on: screen, returnTo: app)
        window.onClose = { [weak self] in self?.lightbox = nil }
        lightbox = window
        window.present()
    }
}
