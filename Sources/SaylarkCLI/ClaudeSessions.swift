import Darwin
import Foundation

/// Reads the messages the user typed (or dictated) into Claude Code from `~/.claude/projects/**/*.jsonl`.
/// Read-only and streamed line by line: the folder is several GB.
enum ClaudeSessions {
    struct Message {
        let time: Date
        let text: String
    }

    /// Human messages sent between `from` and `to`. Sub-agent transcripts, tool results, agent
    /// messages and system notices are skipped.
    static func humanMessages(in root: URL, from: Date, to: Date) throws -> (messages: [Message], files: Int, bytes: Int) {
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "jsonl" && !$0.path.contains("/subagents/") }
        var out: [Message] = []
        var bytes = 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let skipPrefixes = ["<", "[SYSTEM", "This session is being continued", "Base directory for this skill", "Another Claude session", "Caveat:"]
        for file in files {
            // A file last written before the window can't contain messages in it.
            if let mod = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod < from { continue }
            bytes += try forEachLine(of: file, containing: "\"type\":\"user\"") { line in
                if memmemContains(line, "tool_use_id") { return }
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    obj["isSidechain"] as? Bool != true,
                    let ts = (obj["timestamp"] as? String).flatMap(iso.date(from:)), ts >= from, ts <= to,
                    let message = obj["message"] as? [String: Any]
                else { return }
                if let source = obj["promptSource"] as? String, source != "sdk" { return }
                var text = ""
                if let s = message["content"] as? String {
                    text = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !skipPrefixes.contains(where: { text.hasPrefix($0) }) else { return }
                out.append(Message(time: ts, text: text))
            }
        }
        out.sort { $0.time < $1.time }
        return (out, files.count, bytes)
    }

    /// Calls `body` for every line that contains `needle`, reading the file in 8 MB blocks.
    /// Returns the number of bytes read.
    private static func forEachLine(of url: URL, containing needle: String, _ body: (Data) -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var total = 0
        while true {
            let block = try handle.read(upToCount: 8 << 20) ?? Data()
            total += block.count
            if block.isEmpty {
                if !pending.isEmpty, memmemContains(pending, needle) { body(pending) }
                return total
            }
            pending.append(block)
            let n = Array(needle.utf8)
            var consumed = 0
            pending.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while consumed < raw.count, let nl = memchr(base + consumed, 0x0A, raw.count - consumed) {
                    let end = base.distance(to: UnsafeRawPointer(nl))
                    let hit = n.withUnsafeBytes { memmem(base + consumed, end - consumed, $0.baseAddress, n.count) != nil }
                    if hit { body(Data(bytes: base + consumed, count: end - consumed)) }
                    consumed = end + 1
                }
            }
            pending = pending.subdata(in: consumed..<pending.count)
        }
    }

    private static func memmemContains(_ data: Data, _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        return data.withUnsafeBytes { raw in
            n.withUnsafeBytes { nb in
                memmem(raw.baseAddress, raw.count, nb.baseAddress, nb.count) != nil
            }
        }
    }
}
