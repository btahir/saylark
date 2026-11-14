import Foundation

/// One line of the dictionary: a term, spelled the way it should be written, and the forms it gets
/// misheard as ("ship tiffin" for "ShipTiffin").
public struct DictionaryEntry: Sendable, Equatable, Hashable, Identifiable {
    public var term: String
    public var aliases: [String]

    public init(term: String, aliases: [String] = []) {
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = Self.clean(aliases, term: self.term)
    }

    /// Terms that differ only in case or spacing are the same entry.
    public var id: String { SoundKey.spelling(term) }

    /// The line as written to the file: `Term` or `Term: alias, alias`.
    public var line: String { aliases.isEmpty ? term : term + ": " + aliases.joined(separator: ", ") }

    /// Trimmed, non-empty, each once (ignoring case and extra spaces), and never the term itself.
    /// A form with a comma or a line break can't be written back as one alias, so it is dropped.
    public static func clean(_ aliases: [String], term: String) -> [String] {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var seen: Set<String> = [norm(term)]
        var out: [String] = []
        for a in aliases {
            let form = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !SoundKey.spelling(form).isEmpty, !form.contains(","), !form.contains(where: \.isNewline), seen.insert(norm(form)).inserted else { continue }
            out.append(form)
        }
        return out
    }
}

/// The user's dictionary: a plain text file, `~/Library/Application Support/Saylark/dictionary.txt`.
///
/// ```
/// # comments allowed
/// ShipTiffin: ship tiffin, shift tiffin
/// YouTLDR: you tl dr, you tldr
/// Reelbird
/// ```
///
/// A term alone means "spell it this way". Text after the colon lists what it gets misheard as.
/// Parsing never fails: a line that is not a usable entry is skipped (and reported in `problems`),
/// but kept as written, so saving an edit never deletes what the user typed. Comments, blank lines
/// and the order of entries survive edits too.
public struct DictionaryFile: Sendable, Equatable {
    enum Line: Sendable, Equatable {
        /// `raw` is the line as the user wrote it, kept until the entry is edited.
        case entry(DictionaryEntry, raw: String? = nil)
        /// A comment, a blank line, or a line that could not be read. Written back as it was.
        case verbatim(String)
    }

    /// A line that was skipped, 1-based.
    public struct Problem: Sendable, Equatable {
        public var line: Int
        public var text: String
        public var reason: String
    }

    var lines: [Line]
    public private(set) var problems: [Problem] = []

    /// Longest term accepted, in characters. Anything longer is a pasted sentence, not a name.
    public static let maxTermLength = 64

    init(lines: [Line]) { self.lines = lines }

    public init() { lines = Self.header.split(separator: "\n", omittingEmptySubsequences: false).map { .verbatim(String($0)) } }

    /// What a new file starts with.
    public static let header = """
        # Saylark dictionary. One entry per line:
        #   Term                     spell it this way
        #   Term: heard as, heard as  also replace these mishearings with it
        # Lines starting with # are comments. Saylark reloads this file as soon as it changes.

        """

    /// `~/Library/Application Support/Saylark/dictionary.txt`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saylark", isDirectory: true).appendingPathComponent("dictionary.txt")
    }

    // MARK: Reading

    public static func parse(_ text: String) -> DictionaryFile {
        var file = DictionaryFile(lines: [])
        var raw = text.components(separatedBy: .newlines)
        // A final newline is not an extra blank line.
        if raw.last == "" { raw.removeLast() }
        for (i, line) in raw.enumerated() {
            switch parseLine(line) {
            case .success(let entry?): file.lines.append(.entry(entry, raw: line))
            case .success(nil): file.lines.append(.verbatim(line))
            case .failure(let why):
                file.lines.append(.verbatim(line))
                file.problems.append(Problem(line: i + 1, text: line, reason: why.reason))
            }
        }
        return file
    }

    struct Skip: Error { let reason: String }

    /// Nil for a comment or a blank line.
    static func parseLine(_ line: String) -> Result<DictionaryEntry?, Skip> {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return .success(nil) }
        let term: String, aliases: [String]
        if let colon = trimmed.firstIndex(of: ":") {
            term = String(trimmed[..<colon])
            aliases = trimmed[trimmed.index(after: colon)...].split(separator: ",").map(String.init)
        } else {
            term = trimmed
            aliases = []
        }
        let entry = DictionaryEntry(term: term, aliases: aliases)
        if let why = problem(with: entry.term) { return .failure(Skip(reason: why)) }
        return .success(entry)
    }

    /// Why a term can't be used, or nil when it can.
    public static func problem(with term: String) -> String? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "no term before the colon" }
        if SoundKey.spelling(t).isEmpty { return "the term has no letters or digits" }
        if t.count > maxTermLength { return "the term is longer than \(maxTermLength) characters" }
        if t.contains(where: \.isNewline) { return "the term spans more than one line" }
        if t.contains(":") { return "the term has a colon in it" }
        if t.contains(",") { return "the term has a comma in it; put heard-as forms after a colon" }
        if t.hasPrefix("#") { return "a term can't start with #" }
        return nil
    }

    public static func load(_ url: URL) throws -> DictionaryFile {
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// The entries, in file order. A term written twice is one entry with both lines' aliases.
    public var entries: [DictionaryEntry] {
        var out: [DictionaryEntry] = []
        var index: [String: Int] = [:]
        for case .entry(let e, _) in lines {
            if let i = index[e.id] {
                out[i].aliases = DictionaryEntry.clean(out[i].aliases + e.aliases, term: out[i].term)
            } else {
                index[e.id] = out.count
                out.append(e)
            }
        }
        return out
    }

    public func entry(_ term: String) -> DictionaryEntry? {
        let key = SoundKey.spelling(term)
        return entries.first { $0.id == key }
    }

    // MARK: Writing

    /// The file's text, ending in a newline.
    public var text: String {
        lines.map { line in
            switch line {
            case .entry(let e, let raw): raw ?? e.line
            case .verbatim(let s): s
            }
        }.joined(separator: "\n") + "\n"
    }

    /// Adds an entry, or replaces the one with the same term (or with `replacing`, when a term is
    /// renamed) where it stands in the file. Other lines with that term are removed.
    public mutating func set(_ entry: DictionaryEntry, replacing old: String? = nil) {
        let keys: Set<String> = [entry.id, old.map(SoundKey.spelling) ?? entry.id]
        var placed = false
        var out: [Line] = []
        for line in lines {
            if case .entry(let e, _) = line, keys.contains(e.id) {
                // An entry that did not change keeps the user's own formatting.
                if !placed { out.append(e == entry ? line : .entry(entry)); placed = true }
                continue
            }
            out.append(line)
        }
        if !placed {
            // After the last entry, or at the end when there are none yet.
            if let last = out.lastIndex(where: { if case .entry = $0 { true } else { false } }) {
                out.insert(.entry(entry), at: last + 1)
            } else {
                out.append(.entry(entry))
            }
        }
        lines = out
    }

    /// Adds a term, or adds aliases to it when it is already there. Returns the entry as saved.
    @discardableResult
    public mutating func add(_ term: String, aliases: [String] = []) -> DictionaryEntry {
        var entry = self.entry(term) ?? DictionaryEntry(term: term)
        entry.aliases = DictionaryEntry.clean(entry.aliases + aliases, term: entry.term)
        set(entry)
        return entry
    }

    /// Removes every line with this term. Returns false when it was not there.
    @discardableResult
    public mutating func remove(_ term: String) -> Bool {
        let key = SoundKey.spelling(term)
        let before = lines.count
        lines.removeAll { if case .entry(let e, _) = $0 { e.id == key } else { false } }
        return lines.count != before
    }

    /// Writes the file in one step (a temporary file renamed over it), so a reader never sees half.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Loads, changes and writes the file. A missing file starts from the header.
    @discardableResult
    public static func update<T>(_ url: URL, _ change: (inout DictionaryFile) throws -> T) throws -> T {
        var file = FileManager.default.fileExists(atPath: url.path) ? try load(url) : DictionaryFile()
        let result = try change(&file)
        try file.write(to: url)
        return result
    }

    // MARK: Terms for the corrector

    /// The entries as live vocabulary terms. `common` keeps the corrector's guards on: a term spelled
    /// as ordinary words ("Dibs") is never a sound-alike target and gets no case fix, and an alias
    /// made only of ordinary words ("real bird") is swapped only when the recogniser was unsure.
    /// A term with a capital letter is treated as a name the user chose; an all-lowercase term
    /// ("kubectl", "signup") gets the cautious rules: no case-only fix, no joining of ordinary words.
    public func terms(common: CommonWords, at date: Date = Date()) -> [VocabularyTerm] {
        entries.map { e in
            let isName = e.term.contains { $0.isUppercase }
            return VocabularyTerm(
                spelling: e.term,
                aliases: e.aliases.map { HeardAs(form: $0, count: 2, source: .manual) },
                sources: [isName ? .manual : .history], sightings: 2, firstSeen: date, lastSeen: date,
                state: .live, isCommonWord: common.allCommon(e.term))
        }
    }
}
