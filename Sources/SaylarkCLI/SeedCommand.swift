import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark seed <wispr-import-dir>`: transcribes every imported Wispr clip with Parakeet, finds
/// the message the user actually sent in their Claude Code sessions, and harvests names and jargon
/// that Parakeet gets wrong. Writes to `data/seed/` (gitignored: it holds personal text).
///
/// Steps, each resumable:
/// 1. `parakeet.jsonl`: one-pass Parakeet text per clip (skips clips already there).
/// 2. Claude Code messages within the import's time range, matched to each clip by time
///    (sent from 1 min before to 15 min after the dictation) and fuzzy text.
/// 3. `candidates.json`: rare reference words that Parakeet missed, grouped by term, with the
///    forms it heard, counts and short contexts. `matches.jsonl` and `summary.json` hold the rest.
enum SeedCommand {
    struct WisprRow: Decodable {
        let transcriptEntityId: String
        let timestamp: String
        let app: String?
        let duration: Double?
        let asrText: String?
        let pastedText: String?
    }

    struct ParakeetRow: Codable {
        let id: String
        let text: String
        let ms: Double
    }

    struct MatchRow: Codable {
        let id: String
        let app: String
        let category: String
        let matched: Bool
        let score: Double
        let sent: String?
        let sentDelay: Double?
    }

    struct Candidate: Codable {
        var term: String
        let key: String
        /// Clips where Parakeet missed it.
        var sightings = 0
        /// Times the term appears in a reference, and how often Parakeet got it right.
        var occurrences = 0
        var hits = 0
        var heard: [String: Int] = [:]
        var spellings: [String: Int] = [:]
        var sources: [String: Int] = [:]
        var formatOnly = 0
        var examples: [String] = []
        /// Sightings that came from the 80 eval clips (kept out of the boosting A/B).
        var evalSightings = 0
        var dictionaryWord = false
        /// Same references, Wispr's own ASR (only where the sent message was found).
        var wisprOccurrences = 0
        var wisprHits = 0

        var misses: Int { occurrences - hits }
        /// A real name or jargon miss, not noise: seen missed twice, missed at least a quarter of
        /// the time (common words the word list lacks are almost always right), and not mostly a
        /// spacing or hyphen difference ("open source" for "open-source").
        var isTerm: Bool {
            sightings >= 2 && Double(misses) >= 0.25 * Double(occurrences) && formatOnly * 2 < misses
        }
    }

    static func category(_ app: String?) -> String {
        switch app {
        case "com.anthropic.claudefordesktop": "claude"
        case "com.openai.codex": "codex"
        default: "other"
        }
    }

    static func run(_ args: Arguments) async throws {
        let importDir = URL(fileURLWithPath: try args.requirePositional(0, "wispr-import dir"))
        let outDir = URL(fileURLWithPath: args.value("out-dir") ?? "data/seed")
        // Claude Code session logs are read only when asked for (--sessions, or --claude DIR).
        let claudePath = args.value("claude") ?? (args.flag("sessions") ? "~/.claude/projects" : nil)
        let claudeRoot = claudePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let audioDir = importDir.appendingPathComponent("audio")
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: audioDir.path).map { ($0 as NSString).deletingPathExtension })
        let rows = try String(contentsOf: importDir.appendingPathComponent("history.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONDecoder().decode(WisprRow.self, from: Data($0.utf8)) }
            .filter { present.contains($0.transcriptEntityId) }
            .prefix(args.int("limit", 100_000))
        log("\(rows.count) clips with audio")

        // 1. Parakeet over every clip.
        let parakeetURL = outDir.appendingPathComponent("parakeet.jsonl")
        var parakeet: [String: ParakeetRow] = [:]
        if let existing = try? String(contentsOf: parakeetURL, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                if let r = try? JSONDecoder().decode(ParakeetRow.self, from: Data(line.utf8)) { parakeet[r.id] = r }
            }
        }
        let todo = rows.filter { parakeet[$0.transcriptEntityId] == nil }
        if !todo.isEmpty, !args.flag("no-asr") {
            let recognizer = try await Recognizer.load()
            if !FileManager.default.fileExists(atPath: parakeetURL.path) { FileManager.default.createFile(atPath: parakeetURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: parakeetURL)
            try handle.seekToEnd()
            let started = ContinuousClock.now
            for (n, row) in todo.enumerated() {
                let samples = try AudioFile.load(audioDir.appendingPathComponent(row.transcriptEntityId + ".wav"))
                let t = ContinuousClock.now
                let text = samples.count < 1600 ? "" : try await recognizer.transcribe(samples).transcript.text
                let r = ParakeetRow(id: row.transcriptEntityId, text: text, ms: t.msSince)
                parakeet[r.id] = r
                try handle.write(contentsOf: JSONEncoder().encode(r) + Data("\n".utf8))
                if n % 100 == 0 { log("parakeet \(n)/\(todo.count) (\(fmt(started.msSince / 1000)) s)") }
            }
            try handle.close()
            log("parakeet done: \(todo.count) clips in \(fmt(started.msSince / 1000)) s")
        }

        // 2. Sent messages.
        let wisprTime = DateFormatter()
        wisprTime.locale = Locale(identifier: "en_US_POSIX")
        wisprTime.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        let times = rows.compactMap { wisprTime.date(from: $0.timestamp) }
        guard let first = times.min(), let last = times.max() else { throw CLIError("no timestamps") }
        let scanStart = ContinuousClock.now
        let sessions = try claudeRoot.map { try ClaudeSessions.humanMessages(in: $0, from: first.addingTimeInterval(-120), to: last.addingTimeInterval(1200)) }
            ?? (messages: [], files: 0, bytes: 0)
        log("claude: \(sessions.messages.count) human messages from \(sessions.files) files, \(sessions.bytes >> 20) MB read in \(fmt(scanStart.msSince / 1000, 1)) s")
        let messageTokens = sessions.messages.map { TextToken.tokenize($0.text) }

        let harvest = TermHarvest(dictionary: TermHarvest.loadSystemDictionary())
        var evalIds = Set<String>()
        if let evalPath = args.value("eval-manifest"),
            let data = try? Data(contentsOf: URL(fileURLWithPath: (evalPath as NSString).expandingTildeInPath)),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            evalIds = Set(list.compactMap { $0["id"] as? String })
        }

        var candidates: [String: Candidate] = [:]
        var matchRows: [MatchRow] = []
        var tallyParakeetSent = WordErrorTally(), tallyWisprSent = WordErrorTally()
        var tallyParakeetPasted = WordErrorTally()
        for row in rows {
            guard let time = wisprTime.date(from: row.timestamp) else { continue }
            let pasted = (row.pastedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let asr = row.asrText ?? ""
            let cat = category(row.app)

            // Find the sent message: the best fuzzy match among messages sent soon after.
            var best: (score: Double, index: Int, range: Range<Int>)?
            let pastedKeys = TextToken.tokenize(pasted).map(\.key)
            if pastedKeys.count >= 3 {
                var lo = 0, hi = sessions.messages.count
                while lo < hi { let mid = (lo + hi) / 2; if sessions.messages[mid].time < time.addingTimeInterval(-60) { lo = mid + 1 } else { hi = mid } }
                var k = lo
                while k < sessions.messages.count, sessions.messages[k].time <= time.addingTimeInterval(900) {
                    let keys = messageTokens[k].map(\.key)
                    if let m = FuzzyContainment.match(pastedKeys, in: keys), m.score > (best?.score ?? 0.6) {
                        best = (m.score, k, m.range)
                    }
                    k += 1
                }
            }
            var sent: String?
            if let best {
                sent = messageTokens[best.index][best.range].map(\.text).joined(separator: " ")
            }
            matchRows.append(MatchRow(
                id: row.transcriptEntityId, app: row.app ?? "", category: cat, matched: sent != nil, score: best?.score ?? 0,
                sent: sent, sentDelay: best.map { sessions.messages[$0.index].time.timeIntervalSince(time) }))

            // Harvest against the truest reference: the sent text, else what Wispr pasted.
            let reference = sent ?? pasted
            guard !reference.isEmpty, let heard = parakeet[row.transcriptEntityId]?.text else { continue }
            let source = sent != nil ? "sent" : "pasted"
            if sent != nil {
                tallyParakeetSent.add(reference: reference, hypothesis: heard)
                tallyWisprSent.add(reference: reference, hypothesis: asr)
            }
            tallyParakeetPasted.add(reference: pasted, hypothesis: heard)
            let comparison = harvest.compare(reference: reference, heard: heard)
            var seenThisClip = Set<String>()
            for key in comparison.hits {
                candidates[key, default: Candidate(term: key, key: key)].occurrences += 1
                candidates[key]!.hits += 1
            }
            for miss in comparison.misses {
                let key = TermHarvest.groupKey(miss.term)
                var c = candidates[key, default: Candidate(term: miss.term, key: key)]
                c.occurrences += 1
                c.spellings[miss.term, default: 0] += 1
                c.heard[miss.heard.isEmpty ? "(nothing)" : miss.heard, default: 0] += 1
                c.sources[source, default: 0] += 1
                if miss.formatOnly { c.formatOnly += 1 }
                if !seenThisClip.contains(key) {
                    c.sightings += 1
                    seenThisClip.insert(key)
                    if evalIds.contains(row.transcriptEntityId) { c.evalSightings += 1 }
                }
                if c.examples.count < 2 { c.examples.append("\(miss.context)  [heard: \(miss.heard)]") }
                candidates[key] = c
            }
            // Wispr's own ASR against the sent text, for the same rare words.
            if sent != nil {
                let w = harvest.compare(reference: reference, heard: asr)
                for key in w.hits { candidates[key]?.wisprOccurrences += 1; candidates[key]?.wisprHits += 1 }
                for miss in w.misses { candidates[TermHarvest.groupKey(miss.term)]?.wisprOccurrences += 1 }
            }
        }

        // Name the group by its most common spelling; flag plain dictionary words.
        for (key, var c) in candidates {
            if let top = c.spellings.max(by: { $0.value < $1.value })?.key { c.term = top }
            c.dictionaryWord = c.term.split(separator: " ").count == 1 && harvest.dictionary.contains(c.term.lowercased())
            candidates[key] = c
        }
        let missed = candidates.values.filter { $0.sightings > 0 }
            .sorted { ($0.sightings, $0.occurrences) > ($1.sightings, $1.occurrences) }
        try writeJSON(missed, to: outDir.appendingPathComponent("candidates.json"))
        let matchesURL = outDir.appendingPathComponent("matches.jsonl")
        try matchRows.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
            .write(to: matchesURL, atomically: true, encoding: .utf8)

        // Summary.
        var lines: [String] = []
        for cat in ["claude", "codex", "other"] {
            let rs = matchRows.filter { $0.category == cat }
            lines.append("\(cat): \(rs.filter(\.matched).count) of \(rs.count) clips matched a sent Claude Code message")
        }
        lines.append("WER (no fillers) vs sent text: Parakeet \(fmt(tallyParakeetSent.rate * 100, 1))%, Wispr ASR \(fmt(tallyWisprSent.rate * 100, 1))% (\(tallyParakeetSent.words) words)")
        lines.append("WER (no fillers) Parakeet vs pasted: \(fmt(tallyParakeetPasted.rate * 100, 1))%")
        let real = missed.filter { $0.formatOnly < $0.sightings }
        lines.append("\(missed.count) rare words missed at least once (\(real.count) with a real mishearing, not only spacing); \(missed.filter { $0.sightings >= 2 }.count) missed in 2+ clips")
        let terms = missed.filter(\.isTerm)
        let occ = terms.reduce(0) { $0 + $1.occurrences }, miss = terms.reduce(0) { $0 + $1.misses }
        let wOcc = terms.reduce(0) { $0 + $1.wisprOccurrences }, wHit = terms.reduce(0) { $0 + $1.wisprHits }
        lines.append("\(terms.count) terms pass the filter; Parakeet missed \(miss) of \(occ) occurrences (\(fmt(Double(miss) / Double(max(occ, 1)) * 100, 1))%)")
        lines.append("same terms, Wispr ASR vs sent text only: missed \(wOcc - wHit) of \(wOcc) (\(fmt(Double(wOcc - wHit) / Double(max(wOcc, 1)) * 100, 1))%)")
        let sentTerms = terms.filter { $0.wisprOccurrences > 0 }
        lines.append("top terms: " + terms.prefix(50).map { "\($0.term) (\($0.misses)/\($0.occurrences))" }.joined(separator: ", "))
        _ = sentTerms
        print(lines.joined(separator: "\n"))
        try writeJSON(lines, to: outDir.appendingPathComponent("summary.json"))
        log("wrote \(outDir.path)")
    }
}

/// `saylark seed-terms <data/seed>`: picks distinctive seeded terms for vocabulary boosting.
/// Distinctive: missed in at least `--min-sightings` clips, not a plain dictionary word, not only
/// a spacing difference. With `--exclude-eval`, sightings in eval clips don't count.
enum SeedTermsCommand {
    static func run(_ args: Arguments) throws {
        let dir = URL(fileURLWithPath: try args.requirePositional(0, "seed dir"))
        let list = try JSONDecoder().decode([SeedCommand.Candidate].self, from: Data(contentsOf: dir.appendingPathComponent("candidates.json")))
        let minSightings = args.int("min-sightings", 2)
        var picked: [SeedCommand.Candidate] = []
        for c in list where c.isTerm && !c.dictionaryWord
            && c.sightings - (args.flag("exclude-eval") ? c.evalSightings : 0) >= minSightings
        {
            // Names, not formatting: letters, digits, dots and spaces only ("Next.js", "Wispr Flow").
            guard c.term.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == " " }) else { continue }
            let lowerOnly = c.term == c.term.lowercased() && !c.term.contains(where: \.isNumber)
            if lowerOnly && c.term.count < 6 { continue }
            // A near-spelling of a term already picked is usually a misspelling in the reference.
            if picked.contains(where: { closeSpelling($0.key, c.key) }) { continue }
            picked.append(c)
            if picked.count == args.int("max", 40) { break }
        }
        let withAliases = args.flag("aliases")
        let lines = picked.map { c -> String in
            // Aliases: short heard forms only (one or two words, no fillers), most frequent first.
            let aliases = c.heard.sorted { $0.value > $1.value }.map(\.key).filter { form in
                let words = form.lowercased().split(separator: " ")
                return !words.isEmpty && words.count <= 2 && !words.contains(where: { Cleanup.fillers.contains(String($0)) })
                    && form != "(nothing)"
            }.prefix(4)
            return withAliases && !aliases.isEmpty ? "\(c.term)\t\(aliases.joined(separator: "|"))" : c.term
        }
        guard let out = args.value("out") else { print(lines.joined(separator: "\n")); return }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        log("wrote \(lines.count) terms to \(out)")
    }

    /// Character edit distance at most 2, or a quarter of the longer key.
    static func closeSpelling(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let limit = max(2, max(x.count, y.count) / 4)
        guard abs(x.count - y.count) <= limit else { return false }
        return WordAlignment.distance(x.map(String.init), y.map(String.init)) <= limit
    }
}
