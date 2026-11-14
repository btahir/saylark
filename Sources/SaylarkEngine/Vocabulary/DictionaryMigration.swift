import Foundation
import SaylarkCore

/// Moves the old vocabulary (`vocabulary.sqlite`) into the user's `dictionary.txt`, once.
///
/// Only live terms go over, each with the heard-as forms the corrector would have trusted: learned
/// from Saylark's own recogniser (`.asr`, already precision-gated), from a trusted source (manual,
/// a project name, Wispr's dictionary), or seen at least twice. The old store is opened read-only
/// and never changed.
public enum DictionaryMigration {
    public struct Result: Sendable, Equatable {
        public var terms = 0
        public var aliases = 0
        /// Live terms that could not be written as a dictionary line (a colon in the spelling, say).
        public var skipped: [String] = []
    }

    /// The entries the old store's live terms become.
    public static func entries(from terms: [VocabularyTerm]) -> (entries: [DictionaryEntry], skipped: [String]) {
        var entries: [DictionaryEntry] = []
        var skipped: [String] = []
        var seen: Set<String> = []
        for t in terms.sorted(by: { $0.spelling.localizedCaseInsensitiveCompare($1.spelling) == .orderedAscending }) where t.state == .live {
            guard DictionaryFile.problem(with: t.spelling) == nil else { skipped.append(t.spelling); continue }
            let forms = t.aliases.filter { a in a.source == .asr || a.source.isTrusted || a.count >= 2 }.map(\.form)
            let entry = DictionaryEntry(term: t.spelling, aliases: forms)
            guard seen.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }
        return (entries, skipped)
    }

    /// The dictionary text for the old store's live terms.
    public static func file(from terms: [VocabularyTerm], at date: Date = Date()) -> (file: DictionaryFile, result: Result) {
        let (entries, skipped) = entries(from: terms)
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        var file = DictionaryFile.parse(
            DictionaryFile.header + "# Moved here from Saylark's old vocabulary on \(day). Edit freely.\n\n")
        for e in entries { file.set(e) }
        return (file, Result(terms: entries.count, aliases: entries.reduce(0) { $0 + $1.aliases.count }, skipped: skipped))
    }

    /// Writes `dictionary` from `legacy` when the dictionary does not exist yet. Returns nil when
    /// nothing was done (the dictionary is already there, or there is no old store to read).
    @discardableResult
    public static func migrateIfNeeded(dictionary: URL, legacy: URL?, at date: Date = Date()) throws -> Result? {
        guard !FileManager.default.fileExists(atPath: dictionary.path) else { return nil }
        guard let legacy, FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let store = try VocabularyStore(readingOnly: legacy)
        let (file, result) = Self.file(from: try store.liveTerms(), at: date)
        try file.write(to: dictionary)
        return result
    }

    /// Ordinary words learned from the user's writing when the old store was built, read-only.
    /// Empty when there is no old store. Keeps the corrector's "ordinary word" guards as they were.
    public static func ordinaryWords(legacy: URL?) -> Set<String> {
        guard let legacy, let store = try? VocabularyStore(readingOnly: legacy),
              let text = try? store.meta("ordinaryWords") else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }
}
