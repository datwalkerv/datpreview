import AppKit
import PreviewCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = PreviewController()
    private var onboarding: OnboardingWindow?
    private var lastNote = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        controller.onStatusChange = { [weak self] note in self?.lastNote = note }
        controller.start()

        if !Settings.onboardingShown || !(Permissions.accessibility && Permissions.screenRecording) {
            showOnboarding()
            // macOS lists an app under Privacy & Security only after it has asked; without this
            // there's nothing to toggle when the user goes to System Settings directly.
            if !Permissions.accessibility { Permissions.promptAccessibility() }
            if !Permissions.screenRecording { Permissions.promptScreenRecording() }
        }
    }

    private func updateIcon() {
        statusItem.button?.image = Self.menuBarGlyph
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    /// The app icon's `[ picture ]` glyph (assets/icon.svg, same geometry) as a template image,
    /// so the menu bar shows the app's own mark and macOS tints it for light and dark menu bars.
    private static let menuBarGlyph: NSImage = {
        // Glyph bounds in icon.svg units, including half the stroke on each side.
        let bounds = CGRect(x: 277, y: 349, width: 470, height: 326)
        let scale = 16 / bounds.height
        let image = NSImage(size: NSSize(width: (bounds.width * scale).rounded(.up), height: 16), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.translateX(by: -bounds.minX, yBy: -bounds.minY)
            t.concat()

            let path = NSBezierPath()
            for (a, b, c, d) in [(330.0, 290.0, 362.0, 662.0), (694.0, 734.0, 362.0, 662.0)] {
                path.move(to: NSPoint(x: a, y: c))
                path.line(to: NSPoint(x: b, y: c))
                path.line(to: NSPoint(x: b, y: d))
                path.line(to: NSPoint(x: a, y: d))
            }
            path.append(NSBezierPath(roundedRect: NSRect(x: 384, y: 392, width: 256, height: 240), xRadius: 30, yRadius: 30))
            path.move(to: NSPoint(x: 384, y: 584))
            for (x, y) in [(470.0, 506.0), (536, 566), (574, 534), (640, 590)] { path.line(to: NSPoint(x: x, y: y)) }
            path.append(NSBezierPath(ovalIn: NSRect(x: 552, y: 432, width: 44, height: 44)))

            path.lineWidth = 1.5 / scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "datpreview"
        return image
    }()

    // MARK: Menu (rebuilt on open so permission state is always current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(title: "Image Previews", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = Settings.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let hover = NSMenuItem(title: "Hover Delay", action: nil, keyEquivalent: "")
        hover.submenu = NSMenu()
        for option in Settings.HoverDelay.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(setHoverDelay(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = Settings.hoverDelay == option ? .on : .off
            hover.submenu?.addItem(item)
        }
        menu.addItem(hover)

        let size = NSMenuItem(title: "Preview Size", action: nil, keyEquivalent: "")
        size.submenu = NSMenu()
        for option in Settings.PreviewSize.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(setPreviewSize(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = Settings.previewSize == option ? .on : .off
            size.submenu?.addItem(item)
        }
        menu.addItem(size)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let ax = Permissions.accessibility, sr = Permissions.screenRecording
        if ax && sr {
            let ok = NSMenuItem(title: "Permissions Granted", action: nil, keyEquivalent: "")
            ok.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)
            menu.addItem(ok)
        } else {
            let fix = NSMenuItem(title: "Permissions Needed…", action: #selector(showOnboardingAction), keyEquivalent: "")
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(fix)
        }
        if !lastNote.isEmpty {
            let note = NSMenuItem(title: "Last check: \(lastNote)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit datpreview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        for item in menu.items { item.submenu?.items.forEach { $0.target = self } }
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        updateIcon()
    }

    @objc private func setHoverDelay(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double, let d = Settings.HoverDelay(rawValue: v) { Settings.hoverDelay = d }
    }

    @objc private func setPreviewSize(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double, let s = Settings.PreviewSize(rawValue: v) { Settings.previewSize = s }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func showOnboardingAction() { showOnboarding() }

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindow()
            onboarding?.onDone = { [weak self] in
                Settings.onboardingShown = true
                self?.onboarding = nil
            }
        }
        NSApp.activate()
        onboarding?.center()
        onboarding?.makeKeyAndOrderFront(nil)
    }
}
