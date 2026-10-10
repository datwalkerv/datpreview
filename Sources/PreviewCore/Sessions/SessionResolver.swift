import Foundation

public struct TerminalContext: Sendable {
    public let appPID: pid_t
    public let bundleID: String?
    public let windowTitle: String?
    /// tty of the focused tab, when the terminal can tell us.
    public let focusedTTY: String?

    public init(appPID: pid_t, bundleID: String?, windowTitle: String? = nil, focusedTTY: String? = nil) {
        self.appPID = appPID
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusedTTY = focusedTTY
    }
}

public enum ResolveResult: Sendable {
    case found(ImageRecord, LiveSession)
    case noClaudeSession
    case notInTranscript(Int)
}

/// Picks which Claude session an on-screen `[Image #N]` belongs to.
public struct SessionResolver: Sendable {
    public let registry: SessionRegistry

    public init(registry: SessionRegistry) { self.registry = registry }

    public func resolve(number: Int, lineText: String, in context: TerminalContext) -> ResolveResult {
        let candidates = registry.liveSessions().filter { belongs($0, to: context) }
        guard !candidates.isEmpty else { return .noClaudeSession }

        let withImage: [(LiveSession, ImageRecord)] = candidates.compactMap { session in
            // Sent images live (durably) in the transcript; unsent ones only as the paste file.
            if let record = registry.index(for: session.sessionID)?.record(for: number) {
                return (session, record)
            }
            if let file = registry.pastedImageFile(sessionID: session.sessionID, number: number) {
                return (session, ImageRecord(sessionID: session.sessionID, number: number, source: .file(file),
                                             promptText: "", timestamp: nil))
            }
            return nil
        }
        guard !withImage.isEmpty else { return .notInTranscript(number) }
        if withImage.count == 1 { return .found(withImage[0].1, withImage[0].0) }

        if let tty = context.focusedTTY,
           let match = withImage.first(where: { $0.0.tty == tty }) {
            return .found(match.1, match.0)
        }

        let best = withImage.max { a, b in
            score(a, lineText: lineText, context: context) < score(b, lineText: lineText, context: context)
        }!
        return .found(best.1, best.0)
    }

    func belongs(_ session: LiveSession, to context: TerminalContext) -> Bool {
        if session.ancestorPIDs.contains(context.appPID) { return true }
        // iTerm2 runs shells under a separate `iTermServer-x.y.z` daemon parented to launchd.
        if context.bundleID == "com.googlecode.iterm2" {
            return session.ancestorNames.contains { $0.hasPrefix("iTermServer") }
        }
        return false
    }

    private func score(_ pair: (LiveSession, ImageRecord), lineText: String, context: TerminalContext) -> Double {
        let (session, record) = pair
        var s = Self.textOverlap(lineText, record.promptText) * 10
        if let title = context.windowTitle?.lowercased() {
            let project = (session.cwd as NSString).lastPathComponent.lowercased()
            if !project.isEmpty, title.contains(project) { s += 5 }
        }
        // Tie-breaker: most recently active session.
        s += session.updatedAt / 1e13
        return s
    }

    /// Fraction of the on-screen words (minus the reference itself) that appear in the prompt.
    public static func textOverlap(_ screenLine: String, _ prompt: String) -> Double {
        let stripped = screenLine.replacing(#/\[Image\s*[#H≠]?\s*\d+\]/#, with: " ")
        let words = stripped.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }
        guard !words.isEmpty else { return 0 }
        let haystack = prompt.lowercased()
        let hits = words.filter { haystack.contains($0) }.count
        return Double(hits) / Double(words.count)
    }
}
