import Foundation

/// Which project folder the user was working in, from Claude Code session logs
/// (`~/.claude/projects/**/*.jsonl`): every human message records its working folder (`cwd`).
/// Read-only, streamed; only `timestamp` and `cwd` are kept, never message text.
struct SessionFolders: Sendable {
    struct Mark: Sendable {
        let time: Date
        let cwd: String
    }

    let marks: [Mark]

    /// Distinct working folders, worktree paths mapped to their repository.
    var folders: [String] {
        Array(Set(marks.map { Self.repoRoot($0.cwd) })).sorted()
    }

    static func repoRoot(_ path: String) -> String {
        if let r = path.range(of: "/.claude/worktrees/") { return String(path[..<r.lowerBound]) }
        return path
    }

    static func load(root: URL) -> SessionFolders {
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "jsonl" && !$0.path.contains("/subagents/") }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var marks: [Mark] = []
        let timestampPattern = try! NSRegularExpression(pattern: "\"timestamp\":\"([^\"]+)\"")
        let cwdPattern = try! NSRegularExpression(pattern: "\"cwd\":\"([^\"]+)\"")
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            var pending = Data()
            func scan(_ line: Data) {
                // Human messages only: user lines that are not tool results or side chains.
                guard line.count < 2_000_000, let s = String(data: line, encoding: .utf8),
                    s.contains("\"type\":\"user\""), !s.contains("tool_use_id"), !s.contains("\"isSidechain\":true")
                else { return }
                let ns = s as NSString
                guard let t = timestampPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                    let c = cwdPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                    let time = iso.date(from: ns.substring(with: t.range(at: 1)))
                else { return }
                marks.append(Mark(time: time, cwd: ns.substring(with: c.range(at: 1))))
            }
            while let block = try? handle.read(upToCount: 8 << 20), !block.isEmpty {
                pending.append(block)
                while let nl = pending.firstIndex(of: 0x0A) {
                    scan(pending[pending.startIndex..<nl])
                    pending = pending[(nl + 1)...]
                }
                pending = Data(pending)
            }
            if !pending.isEmpty { scan(pending) }
        }
        return SessionFolders(marks: marks.sorted { $0.time < $1.time })
    }

    /// The folder of the session a take in an agent app went to: the first human message sent
    /// within 15 minutes after the take started, else the last one in the 30 minutes before.
    func folder(at time: Date, app: String?) -> String? {
        guard app == "com.anthropic.claudefordesktop", !marks.isEmpty else { return nil }
        var lo = 0, hi = marks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if marks[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        if lo < marks.count, marks[lo].time.timeIntervalSince(time) <= 15 * 60 { return Self.repoRoot(marks[lo].cwd) }
        if lo > 0, time.timeIntervalSince(marks[lo - 1].time) <= 30 * 60 { return Self.repoRoot(marks[lo - 1].cwd) }
        return nil
    }
}
