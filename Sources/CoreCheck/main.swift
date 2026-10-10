import Foundation
import PreviewCore

// Minimal harness: every check prints on failure; the process exits non-zero if any failed.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
func expect(_ ok: @autoclosure () throws -> Bool, _ what: String, line: Int = #line) {
    checks += 1
    let passed = (try? ok()) ?? false
    if !passed { failures += 1; print("  ✗ line \(line): \(what)") }
}
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); print("✓ \(name)") } catch { failures += 1; print("✗ \(name): threw \(error)") }
}

/// Tiny PNGs (1×1 red, 2×1 blue) so ordering mistakes show up as a different image.
private let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
private let png2x1 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAEUlEQVR4nGNgYPj/nwEOAQAz4QL/7rvDXAAAAABJRU5ErkJggg=="

private func pastedTurn(text: String, ids: [Int], images: [String]) -> String {
    let blocks: [[String: Any]] = [["type": "text", "text": text]] + images.map {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0]]
    }
    let obj: [String: Any] = ["type": "user", "imagePasteIds": ids, "timestamp": "2026-10-10T10:00:00Z",
                              "message": ["role": "user", "content": blocks]]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

private func line(_ obj: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

private func tempTranscript(_ lines: [String], trailingNewline: Bool = true) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")
    try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func pixelWidth(_ data: Data) -> Int {
    // PNG IHDR width lives at bytes 16..<20, big-endian.
    data[16..<20].reduce(0) { $0 << 8 | Int($1) }
}

func record(_ index: TranscriptIndex, _ n: Int) throws -> ImageRecord {
    guard let r = index.record(for: n) else { throw NSError(domain: "missing #\(n)", code: 0) }
    return r
}

test("maps imagePasteIds to image blocks in order") {
    let url = try tempTranscript([
        line(["type": "assistant", "message": ["content": "hi"]]),
        pastedTurn(text: "Look at [Image #1] and [Image #2]", ids: [1, 2], images: [png1x1, png2x1]),
    ])
    let index = TranscriptIndex(fileURL: url)
    expect(index.sessionID == "11111111-2222-3333-4444-555555555555", "session id from filename")
    expect(index.allRecords.map(\.number) == [1, 2], "numbers")
    expect(pixelWidth(try TranscriptIndex.loadData(for: try record(index, 1))) == 1, "#1 is the 1px image")
    expect(pixelWidth(try TranscriptIndex.loadData(for: try record(index, 2))) == 2, "#2 is the 2px image")
    expect(try record(index, 2).promptText.contains("[Image #2]"), "prompt text kept")
}

test("keeps gaps from deleted pastes") {
    let index = TranscriptIndex(fileURL: try tempTranscript([
        pastedTurn(text: "[Image #3]", ids: [3], images: [png1x1]),
        pastedTurn(text: "[Image #5]", ids: [5], images: [png2x1]),
    ]))
    expect(index.allRecords.map(\.number) == [3, 5], "numbers 3,5")
    expect(index.record(for: 4) == nil, "#4 absent")
    expect(pixelWidth(try TranscriptIndex.loadData(for: try record(index, 5))) == 2, "#5 bytes")
}

test("slash-command image paths, expired when missing") {
    let command = line(["type": "user", "message": ["role": "user",
        "content": "<command-args>Fix this [Image #1] popping out</command-args>"]])
    let paths = line(["type": "user", "message": ["role": "user", "content": [
        ["type": "text", "text": "[Image: source: /nonexistent/sess/images/1.png]"],
    ]]])
    let index = TranscriptIndex(fileURL: try tempTranscript([command, paths]))
    let r = try record(index, 1)
    let expected = URL(fileURLWithPath: "/nonexistent/sess/images/1.png")
    expect(r.source == .file(expected), "file source")
    expect(r.promptText.contains("popping out"), "inherits prose from the command turn")
    do { _ = try TranscriptIndex.loadData(for: r); expect(false, "should throw") }
    catch { expect((error as? ImageLoadError) == .expired(expected), "throws .expired") }
}

test("picks up appended and partially written lines") {
    let first = pastedTurn(text: "[Image #1]", ids: [1], images: [png1x1])
    let second = pastedTurn(text: "[Image #2]", ids: [2], images: [png2x1])
    let half = second.index(second.startIndex, offsetBy: second.count / 2)
    let url = try tempTranscript([first, String(second[..<half])], trailingNewline: false)
    let index = TranscriptIndex(fileURL: url)
    expect(index.allRecords.map(\.number) == [1], "partial line ignored")
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((String(second[half...]) + "\n").utf8))
    try handle.close()
    expect(index.allRecords.map(\.number) == [1, 2], "completed line picked up")
    expect(pixelWidth(try TranscriptIndex.loadData(for: try record(index, 2))) == 2, "#2 bytes")
}

test("ignores tool_result images") {
    let toolImage = line(["type": "user", "message": ["role": "user", "content": [
        ["type": "tool_result", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png1x1]]]],
    ]]])
    expect(TranscriptIndex(fileURL: try tempTranscript([toolImage])).allRecords.isEmpty, "no records")
}

test("strict reference parsing") {
    let m = ReferenceParser.strictMatches(in: "a [Image #1] b [Image #12] [Image 3]")
    expect(m.map(\.number) == [1, 12], "numbers")
    expect(m.first?.range == NSRange(location: 2, length: 10), "utf16 range")
}

test("OCR-tolerant reference parsing") {
    for (text, n) in [("corners: [Image #15]", 15), ("LImage #2]", 2), ("(Image H7)", 7),
                      ("[Image≠4]", 4), ("IImage #9|", 9)] {
        expect(ReferenceParser.ocrMatches(in: text).map(\.number) == [n], "\(text) → \(n)")
    }
    expect(ReferenceParser.ocrMatches(in: "images #3 and the Image tag").isEmpty, "prose rejected")
}

test("text overlap prefers the matching prompt") {
    let screen = "> Also [Image #1] here the ... gets cutted out by overflow"
    expect(SessionResolver.textOverlap(screen, "Also [Image #1] here the ... gets cutted out by overflow hidden") > 0.9, "right prompt")
    expect(SessionResolver.textOverlap(screen, "[Image #1] boundary selection is broken") < 0.3, "wrong prompt")
}

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) FAILED of \(checks)")
exit(failures == 0 ? 0 : 1)
