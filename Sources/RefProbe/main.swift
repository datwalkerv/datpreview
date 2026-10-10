import AppKit
import PreviewCore
import Vision

// refprobe — proof of concept for the hard part: on-screen `[Image #N]` → the right image bytes.
//
//   refprobe sessions                 live Claude sessions, their tty and process ancestry
//   refprobe index <sessionId|.jsonl> pasted images indexed in a transcript
//   refprobe ocr <image>              run the OCR reference parser on a screenshot file
//   refprobe at <x> <y> [--dump DIR]  one hit-test at a global top-left point
//   refprobe watch [--dump DIR]       hit-test wherever the mouse rests, until Ctrl-C
//   refprobe permissions [--prompt]

let registry = SessionRegistry()
let resolver = SessionResolver(registry: registry)
var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

func describe(_ record: ImageRecord) -> String {
    switch record.source {
    case let .inline(_, offset, length, ordinal, media):
        return "#\(record.number) inline \(media) line@\(offset) (\(length / 1024) KB) block \(ordinal)"
    case .file(let url):
        let exists = FileManager.default.fileExists(atPath: url.path)
        return "#\(record.number) file \(url.path) \(exists ? "" : "(EXPIRED)")"
    }
}

func pixelSize(_ data: Data) -> String {
    guard let rep = NSBitmapImageRep(data: data) else { return "undecodable" }
    return "\(rep.pixelsWide)×\(rep.pixelsHigh)"
}

func probe(at point: CGPoint, dumpDir: String?) async -> String {
    guard let app = NSWorkspace.shared.frontmostApplication else { return "no frontmost app" }
    let outcome = await HitTestPipeline.hitTest(at: point, appPID: app.processIdentifier, bundleID: app.bundleIdentifier)
    let appName = app.localizedName ?? "?"
    guard let hit = outcome.hit else { return "\(appName) · (\(Int(point.x)),\(Int(point.y))) · no reference [\(outcome.note)]" }

    let context = TerminalContext(appPID: app.processIdentifier, bundleID: app.bundleIdentifier)
    var line = "\(appName) · [Image #\(hit.number)] via \(hit.method.rawValue) rect=\(hit.rect.integral) [\(outcome.note)]"
    switch resolver.resolve(number: hit.number, lineText: hit.lineText, in: context) {
    case .noClaudeSession: line += " → no Claude session under this app"
    case .notInTranscript(let n): line += " → #\(n) not found in any live session"
    case let .found(record, session):
        line += " → session \(session.sessionID.prefix(8)) (\(session.tty ?? "?"), \((session.cwd as NSString).lastPathComponent))"
        do {
            let data = try TranscriptIndex.loadData(for: record)
            line += " → \(pixelSize(data)) \(data.count / 1024) KB"
            if let dumpDir {
                let ext = record.source.mediaTypeExtension
                let out = URL(fileURLWithPath: dumpDir).appendingPathComponent("\(session.sessionID.prefix(8))-\(hit.number).\(ext)")
                try data.write(to: out)
                line += " → \(out.path)"
            }
        } catch {
            line += " → load failed: \(error)"
        }
    }
    return line
}

extension ImageSource {
    var mediaTypeExtension: String {
        switch self {
        case .inline(_, _, _, _, let media): return media.split(separator: "/").last.map(String.init) ?? "png"
        case .file(let url): return url.pathExtension
        }
    }
}

/// NSEvent.mouseLocation is bottom-left based on the primary screen; AX/CG use top-left.
func mouseLocationTopLeft() -> CGPoint {
    let p = NSEvent.mouseLocation
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: p.x, y: primaryHeight - p.y)
}

let command = args.isEmpty ? "watch" : args.removeFirst()
let dumpDir = option("--dump")

switch command {
case "sessions":
    print("config dirs: \(registry.configDirs.map(\.path))")
    for s in registry.liveSessions() {
        print("pid \(s.pid) \(s.tty ?? "-") session \(s.sessionID) cwd \(s.cwd)")
        print("   ancestry: \(zip(s.ancestorPIDs, s.ancestorNames).map { "\($0.1)(\($0.0))" }.joined(separator: " → "))")
        let records = registry.index(for: s.sessionID)?.allRecords ?? []
        print("   images: \(records.map { "#\($0.number)" }.joined(separator: " "))")
        let sent = Set(records.map(\.number))
        let unsent = (1...50).filter { !sent.contains($0) && registry.pastedImageFile(sessionID: s.sessionID, number: $0) != nil }
        print("   pasted, not sent: \(unsent.map { "#\($0)" }.joined(separator: " "))")
    }

case "index":
    guard let target = args.first else { print("usage: refprobe index <sessionId|path.jsonl>"); exit(2) }
    let index: TranscriptIndex? = target.hasSuffix(".jsonl")
        ? TranscriptIndex(fileURL: URL(fileURLWithPath: target)) : registry.index(for: target)
    guard let index else { print("transcript not found"); exit(1) }
    let start = Date()
    let records = index.allRecords
    print("\(index.fileURL.path): \(records.count) images, indexed in \(Int(Date().timeIntervalSince(start) * 1000))ms")
    for r in records {
        var s = describe(r)
        if let data = try? TranscriptIndex.loadData(for: r) {
            s += " → \(pixelSize(data))"
            if let dumpDir {
                let out = URL(fileURLWithPath: dumpDir).appendingPathComponent("\(index.sessionID.prefix(8))-\(r.number).\(r.source.mediaTypeExtension)")
                try? data.write(to: out)
            }
        }
        print("  \(s)\n     prompt: \(r.promptText.prefix(90).replacingOccurrences(of: "\n", with: "⏎"))")
    }

case "ocr":
    guard let path = args.first, let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { print("usage: refprobe ocr <image>"); exit(2) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let start = Date()
    try VNImageRequestHandler(cgImage: image).perform([request])
    print("OCR \(Int(Date().timeIntervalSince(start) * 1000))ms")
    for obs in request.results ?? [] {
        let text = obs.topCandidates(1).first?.string ?? ""
        let refs = ReferenceParser.ocrMatches(in: text).map { "#\($0.number)" }
        print("  \(refs.isEmpty ? "  " : "▶ ")\(text)\(refs.isEmpty ? "" : "   → \(refs.joined(separator: ","))")")
    }

case "permissions":
    if args.contains("--prompt") { Permissions.promptAccessibility(); Permissions.promptScreenRecording() }
    print("accessibility: \(Permissions.accessibility)  screenRecording: \(Permissions.screenRecording)")
    print("(when run from a terminal, macOS attributes these to the terminal app itself)")

case "at":
    guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { print("usage: refprobe at x y"); exit(2) }
    print(await probe(at: CGPoint(x: x, y: y), dumpDir: dumpDir))
    if args.contains("--ax-tree") { print(AXHitTester.describe(at: CGPoint(x: x, y: y))) }

case "watch":
    print("Hover over an [Image #N] and hold still. Ctrl-C to quit.")
    print("accessibility: \(Permissions.accessibility)  screenRecording: \(Permissions.screenRecording)")
    var last = CGPoint(x: -1, y: -1)
    var stillSince = Date()
    var probed = false
    var lastLine = ""
    while true {
        try await Task.sleep(for: .milliseconds(60))
        let p = mouseLocationTopLeft()
        if hypot(p.x - last.x, p.y - last.y) > 2 { last = p; stillSince = Date(); probed = false; continue }
        guard !probed, Date().timeIntervalSince(stillSince) > 0.15 else { continue }
        probed = true
        let line = await probe(at: p, dumpDir: dumpDir)
        if line != lastLine { print(line); lastLine = line }
    }

default:
    print("unknown command \(command)")
    exit(2)
}
