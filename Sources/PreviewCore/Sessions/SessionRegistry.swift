import Foundation

/// A running Claude Code process and the session it is currently writing.
public struct LiveSession: Sendable, Equatable {
    public let pid: pid_t
    public let sessionID: String
    public let cwd: String
    public let configDir: URL
    public let updatedAt: Double
    public let tty: String?
    public let ancestorPIDs: [pid_t]
    public let ancestorNames: [String]
}

/// Discovers Claude Code config dirs, live sessions (`sessions/<pid>.json`) and transcripts.
public final class SessionRegistry: @unchecked Sendable {
    public let configDirs: [URL]
    private let lock = NSLock()
    private var indexes: [String: TranscriptIndex] = [:]
    private var transcriptPaths: [String: URL] = [:]

    public init(configDirs: [URL]? = nil) {
        self.configDirs = configDirs ?? Self.defaultConfigDirs()
    }

    public static func defaultConfigDirs() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        candidates.append(home.appendingPathComponent(".claude"))
        // Any other ~/.claude-* profile dir that looks like a Claude config (has projects/).
        if let entries = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in entries.sorted() where name.hasPrefix(".claude-") {
                candidates.append(home.appendingPathComponent(name))
            }
        }
        var seen = Set<String>()
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return fm.fileExists(atPath: url.appendingPathComponent("projects").path)
        }
    }

    /// All Claude Code processes that are alive right now.
    public func liveSessions() -> [LiveSession] {
        var result: [LiveSession] = []
        for dir in configDirs {
            let sessionsDir = dir.appendingPathComponent("sessions")
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path) else { continue }
            for name in files where name.hasSuffix(".json") {
                let url = sessionsDir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (obj["pid"] as? NSNumber)?.int32Value,
                      let sessionID = obj["sessionId"] as? String,
                      ProcessTable.isAlive(pid) else { continue }
                let ancestors = ProcessTable.ancestors(of: pid)
                result.append(LiveSession(
                    pid: pid, sessionID: sessionID,
                    cwd: obj["cwd"] as? String ?? "",
                    configDir: dir,
                    updatedAt: (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0,
                    tty: ProcessTable.info(pid)?.tty,
                    ancestorPIDs: ancestors.map(\.pid),
                    ancestorNames: ancestors.map(\.name)))
            }
        }
        return result
    }

    /// Finds `<configDir>/projects/*/<sessionID>.jsonl`.
    public func transcriptURL(for sessionID: String) -> URL? {
        if let cached = lock.withLock({ transcriptPaths[sessionID] }),
           FileManager.default.fileExists(atPath: cached.path) { return cached }
        let fm = FileManager.default
        for dir in configDirs {
            let projects = dir.appendingPathComponent("projects")
            guard let slugs = try? fm.contentsOfDirectory(atPath: projects.path) else { continue }
            for slug in slugs {
                let candidate = projects.appendingPathComponent(slug).appendingPathComponent("\(sessionID).jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    lock.withLock { transcriptPaths[sessionID] = candidate }
                    return candidate
                }
            }
        }
        return nil
    }

    /// Claude Code writes every paste to `<tmp>/claude-<uid>/<cwd-slug>/<sessionId>/images/N.<ext>`
    /// the moment it's pasted — before the prompt is sent (verified on 2.1.296). That's the only
    /// source for an `[Image #N]` still in the input box.
    public func pastedImageFile(sessionID: String, number: Int) -> URL? {
        let fm = FileManager.default
        for root in Self.pasteRoots {
            guard let slugs = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for slug in slugs {
                let images = root.appendingPathComponent(slug).appendingPathComponent(sessionID)
                    .appendingPathComponent("images")
                guard let files = try? fm.contentsOfDirectory(atPath: images.path) else { continue }
                if let name = files.first(where: { ($0 as NSString).deletingPathExtension == String(number) }) {
                    return images.appendingPathComponent(name)
                }
            }
        }
        return nil
    }

    private static let pasteRoots: [URL] = {
        let dir = "claude-\(getuid())"
        var roots: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CODE_TMPDIR"], !custom.isEmpty {
            roots.append(URL(fileURLWithPath: custom).appendingPathComponent(dir))
        }
        roots.append(URL(fileURLWithPath: "/private/tmp").appendingPathComponent(dir))
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(dir))
        return roots
    }()

    public func index(for sessionID: String) -> TranscriptIndex? {
        if let existing = lock.withLock({ indexes[sessionID] }) { return existing }
        guard let url = transcriptURL(for: sessionID) else { return nil }
        let index = TranscriptIndex(fileURL: url)
        lock.withLock { indexes[sessionID] = index }
        return index
    }
}
