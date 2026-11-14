import Foundation
import GRDB
import SaylarkCore

/// Product and project names from the projects folder and from agent session folders.
public enum ProjectNames {
    public struct Found: Sendable, Equatable {
        public let spelling: String
        /// Folder name, lowercased (what `ProjectSignal` compares with).
        public let folder: String
        public let path: String
    }

    static let markers = ["package.json", "README.md", "Package.swift", ".git", "pyproject.toml", "Cargo.toml", "go.mod", "astro.config.mjs"]
    /// Folder names that are never products.
    static let stop: Set<String> = [
        "projects", "personal", "downloads", "documents", "desktop", "throwaway", "support", "research", "tmp", "temp",
        "src", "app", "apps", "packages", "scripts", "data", "docs", "test", "tests", "worktrees", "claude", "users", "library", "meta",
    ]

    /// Folders under `root` (depth 1, and depth 2 inside folders that are not projects themselves)
    /// plus `extraFolders` (agent session working folders). Multi-word folder names
    /// ("texas-electrician-exam") are skipped: they are spoken as ordinary words.
    /// `casing` maps a spelling key to how the user writes it ("shiptiffin" → "ShipTiffin").
    /// Session folders count only when they are project roots (a README, package or git folder)
    /// and their name is not an ordinary word (`isCommon`): agents often run in sub-folders such
    /// as `audio/` or `results/`.
    public static func scan(root: URL?, extraFolders: [String], casing: [String: String], isCommon: (String) -> Bool = { _ in false }) -> [Found] {
        let fm = FileManager.default
        var folders: [URL] = []
        if let root, let level1 = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for dir in level1 where isDirectory(dir) {
                folders.append(dir)
                if !isProject(dir), let level2 = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
                    folders += level2.filter { isDirectory($0) && isProject($0) }
                }
            }
        }
        let rootPath = root?.standardizedFileURL.path
        for path in extraFolders {
            let dir = URL(fileURLWithPath: repoRoot(path))
            let underRoot = rootPath.map { dir.deletingLastPathComponent().standardizedFileURL.path == $0 } ?? false
            guard underRoot || (isProject(dir) && !isCommon(dir.lastPathComponent)) else { continue }
            folders.append(dir)
        }
        var out: [String: Found] = [:]
        for dir in folders {
            guard let name = projectName(dir, casing: casing) else { continue }
            let key = SoundKey.spelling(name)
            if out[key] == nil { out[key] = Found(spelling: name, folder: dir.lastPathComponent.lowercased(), path: dir.path) }
        }
        return out.values.sorted { $0.spelling < $1.spelling }
    }

    /// `/x/repo/.claude/worktrees/agent-1` → `/x/repo`.
    static func repoRoot(_ path: String) -> String {
        if let r = path.range(of: "/.claude/worktrees/") { return String(path[..<r.lowerBound]) }
        return path
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func isProject(_ url: URL) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// The spelling for one folder, or nil when the folder is not a single-word name.
    static func projectName(_ dir: URL, casing: [String: String]) -> String? {
        var base = dir.lastPathComponent
        for suffix in ["_projects", "-projects", "_project", "-project"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        guard !base.hasPrefix("."), !base.hasPrefix("_"), !base.contains(where: { "-_ .".contains($0) }) else { return nil }
        let key = SoundKey.spelling(base)
        guard key.count >= 3, !stop.contains(key), !key.allSatisfy(\.isNumber) else { return nil }
        if let readme = try? String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8),
            let h1 = readme.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map({ String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }),
            SoundKey.spelling(h1) == key, !h1.contains(" ")
        {
            // The user's own casing beats the README's when they differ only in case.
            if let c = casing[key], c.contains(where: \.isUppercase) { return c }
            return h1
        }
        if let c = casing[key], c.contains(where: \.isUppercase) { return c }
        return base.first!.uppercased() + base.dropFirst()
    }
}

/// Reads Wispr Flow's database from a copy (APFS clone), never the live files. Text columns only.
public final class WisprVocabularyReader {
    public struct DictionaryEntry: Sendable {
        public let phrase: String
        public let replacement: String?
        public let manual: Bool
        public let source: String?
        public let heard: String?
        public let uses: Int
        public let isSnippet: Bool
        public let isDeleted: Bool
        public let createdAt: Date?
    }

    public struct HistoryRow: Sendable {
        public let at: Date
        public let app: String?
        public let asr: String
        public let formatted: String
        public let edited: String
    }

    private let temp: URL
    private let queue: DatabaseQueue

    /// Wispr Flow's database, for a one-time import (`saylark vocab build`). The app never reads it.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
    }

    /// Sequelize writes dates as text ("2026-08-14 21:58:58.257 +00:00"); accept epoch numbers too.
    static func date(_ value: DatabaseValue) -> Date? {
        switch value.storage {
        case .string(let s): parseTimestamp(s)
        case .double(let d): Date(timeIntervalSince1970: d > 1e11 ? d / 1000 : d)
        case .int64(let i): Date(timeIntervalSince1970: i > 100_000_000_000 ? Double(i) / 1000 : Double(i))
        default: nil
        }
    }

    /// Parses Wispr's timestamp format, e.g. "2026-08-14 21:58:58.257 +00:00".
    static func parseTimestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS xxx", "yyyy-MM-dd HH:mm:ss xxx", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd HH:mm:ss.SSS"] {
            f.dateFormat = format
            if format.hasSuffix("SSS") { f.timeZone = TimeZone(identifier: "UTC") }
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    public init(databaseURL: URL = WisprVocabularyReader.defaultURL) throws {
        let fm = FileManager.default
        temp = fm.temporaryDirectory.appendingPathComponent("saylark-vocab-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let copy = temp.appendingPathComponent("flow.sqlite")
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        if fm.fileExists(atPath: wal.path) { try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
        try fm.copyItem(at: databaseURL, to: copy)
        queue = try DatabaseQueue(path: copy.path)
    }

    deinit {
        try? queue.close()
        try? FileManager.default.removeItem(at: temp)
    }

    public func dictionary() throws -> [DictionaryEntry] {
        try queue.read { db in
            guard try db.tableExists("Dictionary") else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT phrase, replacement, manualEntry, source, observedSource, frequencyUsed, isSnippet, isDeleted, createdAt FROM Dictionary
                """).map { r in
                DictionaryEntry(
                    phrase: r["phrase"] ?? "", replacement: r["replacement"], manual: (r["manualEntry"] as Int?) == 1,
                    source: r["source"], heard: r["observedSource"], uses: r["frequencyUsed"] ?? 0,
                    isSnippet: (r["isSnippet"] as Int?) == 1, isDeleted: (r["isDeleted"] as Int?) == 1,
                    createdAt: Self.date(r["createdAt"]))
            }
        }
    }

    public func history(before: Date?) throws -> [HistoryRow] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT timestamp, app, asrText, formattedText, editedText FROM History
                WHERE status = 'formatted' ORDER BY timestamp
                """).compactMap { r in
                guard let at = Self.date(r["timestamp"]) else { return nil }
                if let before, at >= before { return nil }
                return HistoryRow(at: at, app: r["app"], asr: r["asrText"] ?? "", formatted: r["formattedText"] ?? "", edited: r["editedText"] ?? "")
            }
        }
    }
}

/// Fills a `VocabularyBook` from every automatic source, in trust order: projects, then past
/// dictations (rare words), then Wispr's dictionary (junk rules applied), then corrections, then
/// heard-as forms mined from past dictations.
public enum VocabularyBuilder {
    public struct Input {
        public var projectsRoot: URL?
        /// Working folders of Claude Code / Codex sessions.
        public var sessionFolders: [String] = []
        public var wisprHistory: [WisprVocabularyReader.HistoryRow] = []
        public var wisprDictionary: [WisprVocabularyReader.DictionaryEntry] = []
        /// Evidence dated at or after this is ignored (evals build a store as of a cutoff).
        public var before: Date?
        /// The project folder a past take was spoken in (agent apps), if known.
        public var projectAt: (@Sendable (Date, String?) -> String?)?
        public var now = Date()

        public init(projectsRoot: URL?) {
            self.projectsRoot = projectsRoot
        }
    }

    public struct Report: Sendable, CustomStringConvertible {
        public var projects: [String] = []
        public var historyTerms = 0
        public var dictionaryImported: [String] = []
        public var dictionaryBlocked: [String] = []
        public var dictionarySkipped: [String] = []
        public var corrections = 0
        public var folded: [String] = []
        public var aliasesMined = 0
        /// Words added to the ordinary-word list from the user's own writing (saved with the store).
        public var ordinaryWords: [String] = []
        /// Terms the user writes apart from a following number ("Opus 4.5").
        public var writtenApartFromNumbers: [String] = []

        public var description: String {
            """
            projects: \(projects.count) (\(projects.joined(separator: ", ")))
            history terms (>= 2 sightings): \(historyTerms)
            Wispr dictionary imported: \(dictionaryImported.count); blocked as junk: \(dictionaryBlocked.count); skipped: \(dictionarySkipped.count)
              blocked: \(dictionaryBlocked.joined(separator: "; "))
            corrections from edits: \(corrections)
            mishearings folded into terms: \(folded.count) (\(folded.joined(separator: ", ")))
            heard-as forms mined: \(aliasesMined)
            ordinary words learned from his writing: \(ordinaryWords.count)
            written apart from numbers: \(writtenApartFromNumbers.count) (\(writtenApartFromNumbers.joined(separator: ", ")))
            """
        }
    }

    static func stripHTML(_ s: String) -> String {
        s.contains("<") ? s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : s
    }

    /// Words written in lower case mid-sentence at least 90% of the time, 4+ times.
    static func ordinaryWords(_ rows: [WisprVocabularyReader.HistoryRow]) -> Set<String> {
        var lower: [String: Int] = [:], total: [String: Int] = [:]
        for r in rows {
            for t in TextToken.tokenize(stripHTML(r.edited.isEmpty ? r.formatted : r.edited)) where !t.sentenceStart {
                guard t.text.allSatisfy(\.isLetter) else { continue }
                total[t.key, default: 0] += 1
                if t.text == t.text.lowercased() { lower[t.key, default: 0] += 1 }
            }
        }
        return Set(total.filter { $0.value >= 4 && Double(lower[$0.key] ?? 0) >= 0.9 * Double($0.value) }.keys)
    }

    /// "open-source", "high-level", "5-second": hyphenated ordinary words or numbers are
    /// formatting, not names.
    static func isFormattingCompound(_ text: String, common: CommonWords) -> Bool {
        guard text.contains("-") || text.contains("/") else { return false }
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)
        return parts.allSatisfy { common.contains($0) || $0.allSatisfy(\.isNumber) || $0.count <= 1 }
    }

    /// Words that never start or end a heard-as phrase ("Short Candy we" is "short candy").
    static let edgeWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "be", "we", "i", "you", "it", "and", "or", "but", "so", "to", "of", "in", "on",
        "for", "with", "at", "by", "like", "know", "if", "that", "this", "then", "there", "what", "my", "our", "your",
    ]

    /// How the user writes each rare word most often (`casing["shiptiffin"] == "ShipTiffin"`).
    static func casing(_ rows: [WisprVocabularyReader.HistoryRow]) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for r in rows {
            for t in TextToken.tokenize(stripHTML(r.formatted)) where !t.sentenceStart {
                counts[t.key, default: [:]][t.text, default: 0] += 1
            }
        }
        return counts.mapValues { $0.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key }
    }

    public static func build(into book: inout VocabularyBook, _ input: Input, common system: CommonWords) -> Report {
        var report = Report()
        let rows = input.wisprHistory.filter { input.before == nil || $0.at < input.before! }
        let casingHints = casing(rows)
        // The system word list is from 1934 ("database", "online", "email" are missing): words the
        // user writes in lower case nearly always are ordinary words for him too.
        report.ordinaryWords = ordinaryWords(rows).subtracting(system.words).sorted()
        let common = CommonWords(system.words.union(report.ordinaryWords))
        let stamp = input.before.map { min($0, input.now) } ?? input.now

        // 1. Projects (trusted): the user's own product names.
        for p in ProjectNames.scan(root: input.projectsRoot, extraFolders: input.sessionFolders, casing: casingHints, isCommon: common.contains) {
            book.observe(TermObservation(
                spelling: p.spelling, source: .project, projects: [p.folder], at: stamp, isCommonWord: common.contains(p.spelling)))
            report.projects.append(p.spelling)
        }

        // 2. Rare words said at least twice (dictionary words only when nearly always capitalised mid-sentence).
        let harvest = TermHarvest(dictionary: common.words)
        struct Seen { var rare = 0; var total = 0; var spellings: [String: Int] = [:]; var last = Date.distantPast; var projects: Set<String> = [] }
        var seen: [String: Seen] = [:]
        for r in rows {
            let project = input.projectAt?(r.at, r.app).map { ($0 as NSString).lastPathComponent.lowercased() }
            for t in TextToken.tokenize(stripHTML(r.edited.isEmpty ? r.formatted : r.edited)) {
                seen[t.key, default: Seen()].total += 1
                guard harvest.isRare(t), !isFormattingCompound(t.text, common: common) else { continue }
                seen[t.key]!.rare += 1
                seen[t.key]!.spellings[t.text, default: 0] += 1
                seen[t.key]!.last = max(seen[t.key]!.last, r.at)
                if let project { seen[t.key]!.projects.insert(project) }
            }
        }
        for (key, s) in seen.sorted(by: { $0.key < $1.key }) where s.rare >= 2 {
            let isCommon = common.contains(key)
            if isCommon, s.rare < 3 || Double(s.rare) < 0.8 * Double(s.total) { continue }
            let spelling = s.spellings.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
            let outcome = book.observe(TermObservation(
                spelling: spelling, source: .history, projects: s.projects.sorted(), count: s.rare, at: s.last, isCommonWord: isCommon))
            if case .rejected = outcome { continue }
            report.historyTerms += 1
        }

        // 3. Wispr's dictionary: manual words as trusted terms, learned replacements through the junk rules.
        for e in input.wisprDictionary {
            if let before = input.before, let c = e.createdAt, c >= before { continue }
            if e.isDeleted || e.isSnippet || (e.replacement?.isEmpty == false) {
                report.dictionarySkipped.append(e.phrase + (e.isSnippet ? " (snippet)" : e.replacement?.isEmpty == false ? " (text replacement)" : " (deleted)"))
                continue
            }
            let at = e.createdAt ?? stamp
            if let heard = e.heard, !heard.isEmpty, !e.manual {
                if case .rejected(let why) = book.observeLearned(spelling: e.phrase, heard: heard, source: .wisprDictionary, count: max(1, e.uses), at: at) {
                    report.dictionaryBlocked.append("\(e.phrase) <- \(heard): \(why)")
                } else {
                    report.dictionaryImported.append("\(e.phrase) <- \(heard)")
                }
            } else if let why = VocabularyBook.junkReason(spelling: e.phrase) {
                report.dictionarySkipped.append("\(e.phrase) (\(why))")
            } else {
                book.observe(TermObservation(spelling: e.phrase, source: .wisprDictionary, count: max(1, e.uses), at: at, isCommonWord: common.allCommon(e.phrase)))
                report.dictionaryImported.append(e.phrase)
            }
        }

        // 4. Corrections: rare words the user typed over what was pasted. (Compared with the pasted
        //    text, not the raw ASR, so Wispr's own formatting changes do not count as corrections.)
        for r in rows where !r.edited.isEmpty {
            for miss in harvest.compare(reference: stripHTML(r.edited), heard: stripHTML(r.formatted)).misses where !miss.formatOnly && !miss.heard.isEmpty {
                guard miss.term.split(separator: " ").count == 1, !common.contains(miss.term) else { continue }
                if case .rejected = book.observeLearned(spelling: miss.term, heard: miss.heard, source: .correction, count: 1, at: r.at, block: false) { continue }
                report.corrections += 1
            }
        }

        // 5. Spellings seen only in past dictations that sound like a trusted term are mishearings
        //    ("Shiftify" → ShipTiffin): fold them in as heard-as forms.
        report.folded = book.foldMishearings().map { "\($0.from) -> \($0.into)" }

        // 6. Heard-as forms: phrases in past dictations that sound and look like a distinctive term.
        book.refresh(now: input.now)
        report.aliasesMined = mineAliases(into: &book, rows: rows, common: common)

        // 7. Whether each term is written apart from a following number ("Opus 4.5"), so the
        //    recogniser's "Opus4.5" can be split and identifiers ("base64") are left alone.
        let keys = Set(book.terms.map(\.key))
        var apart: [String: Int] = [:], joined: [String: Int] = [:]
        for r in rows {
            let c = NumberSpacing.count(in: stripHTML(r.edited.isEmpty ? r.formatted : r.edited), keys: keys)
            for (k, v) in c.apart { apart[k, default: 0] += v }
            for (k, v) in c.joined { joined[k, default: 0] += v }
        }
        book.recordNumberSpacing(apart: apart, joined: joined)
        report.writtenApartFromNumbers = book.terms.filter(\.isWrittenApartFromNumbers).map(\.spelling).sorted()
        return report
    }

    /// Finds 1–3 word phrases in past text (Wispr's ASR and formatted text) that sound like a
    /// distinctive live term (not a dictionary word, 5+ letters) but are spelled differently, and
    /// records the ones seen at least twice as heard-as forms. A single ordinary word is never
    /// taken ("cloud" is not recorded for "Claude").
    public static func mineAliases(
        into book: inout VocabularyBook, rows: [WisprVocabularyReader.HistoryRow], common: CommonWords,
        soundMin: Double = 0.75, spellingMin: Double = 0.6
    ) -> Int {
        let targets = book.terms.filter { ($0.state == .live || $0.state == .candidate) && !$0.isCommonWord && $0.key.count >= 5 }
        guard !targets.isEmpty else { return 0 }
        let known = Set(book.terms.map(\.key))
        var byFirst: [Character: [VocabularyTerm]] = [:]
        for t in targets { if let f = t.sound.first { byFirst[f, default: []].append(t) } }
        var counts: [String: [String: (form: String, n: Int, last: Date)]] = [:]  // term key -> phrase key -> form
        var memo: [String: String?] = [:]
        for r in rows {
            for text in Set([r.asr, stripHTML(r.formatted)]) {
                let toks = TextToken.tokenize(text)
                for i in toks.indices {
                    for n in 1...3 where i + n <= toks.count {
                        let span = toks[i..<(i + n)]
                        if edgeWords.contains(span.first!.key) || edgeWords.contains(span.last!.key) { break }
                        let key = span.map(\.key).joined()
                        guard key.count >= 4, !known.contains(key) else { continue }
                        let form = span.map(\.text).joined(separator: " ")
                        // A phrase that holds a known term ("ShipTiffin is") is not a mishearing of it.
                        if span.contains(where: { known.contains($0.key) }) { continue }
                        let allCommon = common.allCommon(form)
                        if n == 1, allCommon { continue }
                        let match: String?
                        if let m = memo[key] { match = m } else {
                            let sound = SoundKey.sound(form)
                            var best: (String, Double)?
                            // Ordinary-word phrases ("real bird") must be closer than odd spellings ("Headsner").
                            // So must anything heard for a term known only from past dictations.
                            for t in byFirst[sound.first ?? " "] ?? [] where abs(t.key.count - key.count) <= 3 && !key.contains(t.key) {
                                let strict = allCommon || !t.bestSource.isTrusted
                                let needSound = strict ? max(soundMin, 0.85) : soundMin
                                let needSpelling = strict ? max(spellingMin, 0.75) : spellingMin
                                let s = SoundKey.similarity(sound, t.sound), p = SoundKey.similarity(key, t.key)
                                if s >= needSound, p >= needSpelling, best == nil || s + p > best!.1 { best = (t.key, s + p) }
                            }
                            match = best?.0
                            memo[key] = match
                        }
                        guard let termKey = match else { continue }
                        var entry = counts[termKey, default: [:]][key] ?? (form, 0, .distantPast)
                        entry.n += 1
                        entry.last = max(entry.last, r.at)
                        counts[termKey, default: [:]][key] = entry
                        break  // shortest match at this start wins
                    }
                }
            }
        }
        var added = 0
        for (termKey, phrases) in counts.sorted(by: { $0.key < $1.key }) {
            guard let term = book.term(termKey) else { continue }
            for (_, p) in phrases.sorted(by: { $0.key < $1.key }) where p.n >= 2 {
                book.observe(TermObservation(spelling: term.spelling, source: .history, heardAs: [p.form: p.n], count: 0, at: p.last))
                added += 1
            }
        }
        return added
    }
}
