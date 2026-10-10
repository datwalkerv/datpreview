import Foundation

/// Where the bytes of one `[Image #N]` live.
public enum ImageSource: Equatable, Sendable {
    /// A base64 `image` block inside a transcript line. Only the line's byte range is kept;
    /// the payload is decoded on demand.
    case inline(file: URL, lineOffset: UInt64, lineLength: Int, imageOrdinal: Int, mediaType: String)
    /// A path Claude Code wrote for slash-command turns (`[Image: source: …/images/N.png]`).
    /// Lives in /tmp and may have expired.
    case file(URL)
}

public struct ImageRecord: Equatable, Sendable {
    public let sessionID: String
    public let number: Int
    public let source: ImageSource
    /// Prompt text the reference appeared in; used to disambiguate between sessions.
    public let promptText: String
    public let timestamp: String?
}

public enum ImageLoadError: Error, Equatable {
    case expired(URL)
    case unreadable
    case malformed
}

/// Incremental index of the pasted images in one Claude Code transcript (`<sessionId>.jsonl`).
///
/// Transcript format (undocumented, verified on Claude Code 2.1.x):
/// a typed user turn with pasted images carries top-level `"imagePasteIds": [n, …]` and its
/// `message.content` lists `image` blocks in the same order as those ids. Slash-command turns
/// instead contain text blocks `[Image: source: /…/images/N.png]`.
public final class TranscriptIndex: @unchecked Sendable {
    public let fileURL: URL
    public let sessionID: String

    private let lock = NSLock()
    private var readOffset: UInt64 = 0
    private var fileID: UInt64?
    private var records: [Int: ImageRecord] = [:]
    /// Last user text that mentioned `[Image #…]`; slash-command turns put the prose and the
    /// image paths in separate lines.
    private var lastReferencingText = ""

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.sessionID = fileURL.deletingPathExtension().lastPathComponent
    }

    public var allRecords: [ImageRecord] {
        refresh()
        return lock.withLock { records.values.sorted { $0.number < $1.number } }
    }

    public func record(for number: Int) -> ImageRecord? {
        refresh()
        return lock.withLock { records[number] }
    }

    /// Reads whatever was appended since the last call. Cheap when nothing changed (one stat).
    public func refresh() {
        lock.lock(); defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if inode != fileID || size < readOffset {
            // Replaced or truncated: start over.
            fileID = inode
            readOffset = 0
            records = [:]
            lastReferencingText = ""
        }
        guard size > readOffset, let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        let chunkSize = 4 << 20
        var pending = Data()
        var pendingStart = readOffset
        try? handle.seek(toOffset: readOffset)
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let nl = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[lineStart..<nl]
                processLine(line, offset: pendingStart + UInt64(lineStart - pending.startIndex))
                lineStart = nl + 1
            }
            // Keep the incomplete tail (a line still being written) for the next chunk / refresh.
            pendingStart += UInt64(lineStart - pending.startIndex)
            pending = Data(pending[lineStart...])
        }
        readOffset = pendingStart
    }

    private static let pasteIDsMarker = Data("\"imagePasteIds\"".utf8)
    private static let sourceMarker = Data("[Image: source: ".utf8)
    private static let referenceMarker = Data("[Image #".utf8)

    private func processLine(_ line: Data, offset: UInt64) {
        let hasPasteIDs = line.range(of: Self.pasteIDsMarker) != nil
        let hasSourcePaths = line.range(of: Self.sourceMarker) != nil
        let hasReferences = line.range(of: Self.referenceMarker) != nil
        guard hasPasteIDs || hasSourcePaths || hasReferences,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "user",
              let message = obj["message"] as? [String: Any] else { return }

        let timestamp = obj["timestamp"] as? String
        let blocks = message["content"] as? [[String: Any]] ?? []
        let promptText = (message["content"] as? String) ?? blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if hasReferences { lastReferencingText = promptText }

        if hasPasteIDs, let ids = obj["imagePasteIds"] as? [Int] {
            let images = blocks.filter { $0["type"] as? String == "image" }
            for (ordinal, id) in ids.enumerated() where ordinal < images.count {
                let src = images[ordinal]["source"] as? [String: Any]
                let media = src?["media_type"] as? String ?? "image/png"
                records[id] = ImageRecord(
                    sessionID: sessionID, number: id,
                    source: .inline(file: fileURL, lineOffset: offset, lineLength: line.count,
                                    imageOrdinal: ordinal, mediaType: media),
                    promptText: promptText, timestamp: timestamp)
            }
        }

        if hasSourcePaths {
            for path in Self.sourcePaths(in: promptText) {
                let url = URL(fileURLWithPath: path)
                guard let n = Int(url.deletingPathExtension().lastPathComponent),
                      records[n] == nil else { continue }
                records[n] = ImageRecord(sessionID: sessionID, number: n, source: .file(url),
                                         promptText: lastReferencingText, timestamp: timestamp)
            }
        }
    }

    static func sourcePaths(in text: String) -> [String] {
        let regex = #/\[Image: source: ([^\]\n]+)\]/#
        return text.matches(of: regex).map { String($0.output.1) }
    }

    // MARK: - Loading

    /// Returns the raw encoded image bytes (PNG/JPEG/…) for a record.
    public static func loadData(for record: ImageRecord) throws -> Data {
        switch record.source {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw ImageLoadError.expired(url) }
            guard let data = try? Data(contentsOf: url) else { throw ImageLoadError.unreadable }
            return data
        case let .inline(file, offset, length, ordinal, _):
            guard let handle = try? FileHandle(forReadingFrom: file) else { throw ImageLoadError.unreadable }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let line = try? handle.read(upToCount: length), line.count == length,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { throw ImageLoadError.unreadable }
            let images = blocks.filter { $0["type"] as? String == "image" }
            guard ordinal < images.count,
                  let b64 = (images[ordinal]["source"] as? [String: Any])?["data"] as? String,
                  let data = Data(base64Encoded: b64) else { throw ImageLoadError.malformed }
            return data
        }
    }
}
