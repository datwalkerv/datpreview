import AppKit
import PreviewCore

/// One small window explaining the two permissions and why each is needed. Rows update live.
final class OnboardingWindow: NSWindow, NSWindowDelegate {
    var onDone: (() -> Void)?
    private var rows: [PermissionRow] = []
    private var timer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: "Image previews for Claude Code")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Hover over [Image #N] in your terminal to peek at the image; click it to open it larger. datpreview never changes what your terminal shows or receives.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        rows = [
            PermissionRow(symbol: "accessibility", title: "Accessibility",
                          detail: "Reads the text under the pointer in Terminal and iTerm2.",
                          granted: { Permissions.accessibility },
                          grant: {
                              Permissions.promptAccessibility()
                              Self.openSettings("Privacy_Accessibility")
                          }),
            PermissionRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                          detail: "Reads a small strip around the pointer in terminals without accessible text, like Zed. Nothing is saved.",
                          granted: { Permissions.screenRecording },
                          grant: {
                              Permissions.promptScreenRecording()
                              Self.openSettings("Privacy_ScreenCapture")
                          }),
        ]

        let done = NSButton(title: "Done", target: nil, action: nil)
        done.keyEquivalent = "\r"
        done.target = self
        done.action = #selector(finish)

        let header = NSStackView(views: [icon, title])
        header.spacing = 10
        let stack = NSStackView(views: [header, subtitle] + rows + [done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: subtitle)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        done.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            subtitle.widthAnchor.constraint(equalToConstant: 392),
            done.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -24),
        ] + rows.map { $0.widthAnchor.constraint(equalToConstant: 392) })

        // Permission grants happen in System Settings; reflect them as soon as they change.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.rows.forEach { $0.refresh() }
        }
    }

    @objc private func finish() { close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onDone?()
    }

    private static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class PermissionRow: NSStackView {
    private let granted: () -> Bool
    private let grant: () -> Void
    private let button = NSButton(title: "Grant…", target: nil, action: nil)
    private let check = NSImageView()

    init(symbol: String, title: String, detail: String, granted: @escaping () -> Bool, grant: @escaping () -> Void) {
        self.granted = granted
        self.grant = grant
        super.init(frame: .zero)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let info = NSTextField(wrappingLabelWithString: detail)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, info])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(grantTapped)
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
        check.contentTintColor = .systemGreen
        check.symbolConfiguration = .init(pointSize: 16, weight: .regular)

        setViews([icon, text, button, check], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let ok = granted()
        button.isHidden = ok
        check.isHidden = !ok
    }

    @objc private func grantTapped() { grant() }
}
