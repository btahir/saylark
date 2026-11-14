import Foundation
import GRDB
import SaylarkCore

/// The dictionary on disk: one SQLite row per term (GRDB, like `HistoryStore`). Lives at
/// `~/Library/Application Support/Saylark/vocabulary.sqlite`; tests and evals pass their own path.
///
/// The rules live in `VocabularyBook` (pure). The store loads the book, lets the caller change it,
/// runs `refresh` (live / retired / cap) and writes every row back in one transaction, so a reader
/// never sees half an update.
public final class VocabularyStore: Sendable {
    public let url: URL
    private let db: DatabaseQueue

    public static var defaultURL: URL {
        HistoryStore.defaultFolder.appendingPathComponent("vocabulary.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "saylark.vocabulary"
        db = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(db)
    }

    /// Opens an existing store without changing it: no folder, no migration, read-only SQLite.
    /// Used to move the old vocabulary into `dictionary.txt`. Throws when the file is missing.
    public init(readingOnly url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        var config = Configuration()
        config.label = "saylark.vocabulary.readonly"
        config.readonly = true
        db = try DatabaseQueue(path: url.path, configuration: config)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "vocab_term") { t in
                t.column("key", .text).primaryKey()
                t.column("spelling", .text).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("sightings", .integer).notNull()
                t.column("lastSeen", .double).notNull()
                /// The whole `VocabularyTerm` as JSON (aliases, sources, projects, note).
                t.column("body", .jsonText).notNull()
            }
            try db.create(table: "vocab_meta") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2-heard-as") { db in
            // Heard-as forms learned from Saylark's own recogniser vs a reference (`HeardAsLearner`).
            // Kept apart from `vocab_term`, so `saylark vocab build` never erases them.
            try db.create(table: "vocab_heard") { t in
                t.column("id", .text).primaryKey()
                t.column("formKey", .text).notNull()
                t.column("termKey", .text).notNull().indexed()
                t.column("state", .text).notNull()
                t.column("hits", .integer).notNull()
                t.column("seen", .integer).notNull()
                t.column("body", .jsonText).notNull()
            }
        }
        return m
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func load(rules: VocabularyRules = VocabularyRules()) throws -> VocabularyBook {
        let bodies = try db.read { db in try String.fetchAll(db, sql: "SELECT body FROM vocab_term ORDER BY key") }
        let terms = try bodies.map { try Self.decoder.decode(VocabularyTerm.self, from: Data($0.utf8)) }
        return VocabularyBook(terms: terms, rules: rules)
    }

    /// Replaces every row with the book's terms.
    public func save(_ book: VocabularyBook) throws {
        let rows = try book.terms.map { t in
            (t, String(decoding: try Self.encoder.encode(t), as: UTF8.self))
        }
        try db.write { db in
            try db.execute(sql: "DELETE FROM vocab_term")
            for (t, body) in rows {
                try db.execute(
                    sql: "INSERT INTO vocab_term (key, spelling, state, sightings, lastSeen, body) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [t.key, t.spelling, t.state.rawValue, t.sightings, t.lastSeen.timeIntervalSince1970, body])
            }
        }
    }

    /// Load, change, refresh states as of `now`, save. Returns the saved book.
    @discardableResult
    public func update(now: Date = Date(), rules: VocabularyRules = VocabularyRules(), _ change: (inout VocabularyBook) throws -> Void) throws -> VocabularyBook {
        var book = try load(rules: rules)
        try change(&book)
        book.refresh(now: now)
        try save(book)
        return book
    }

    /// Live terms, best first is not implied (ordered by key); rank with `TermRanker` per take.
    /// Live learned heard-as forms are attached as `.asr` aliases.
    public func liveTerms() throws -> [VocabularyTerm] {
        try heardAs().applying(to: load().live)
    }

    // MARK: - Heard-as forms learned from the recogniser

    /// Every learned heard-as candidate (live, candidate and retired), with its counts.
    public func heardAs(rules: HeardAsLearner.Rules = .init()) throws -> HeardAsLearner {
        try db.read { db in try Self.readLearner(db, rules: rules) }
    }

    /// Batch learning (evals and tests): hits from every take, `seen` counted over all of
    /// them, and the user's literal uses of each form counted in the references plus `writing`
    /// (his past dictations). Adds to what is already stored.
    public func learnAll(_ takes: [(heard: String, reference: String, at: Date)], writing: [String] = [], rules: HeardAsLearner.Rules = .init()) throws -> HeardAsLearner {
        let common = try commonWords()
        return try db.write { db in
            var learner = try Self.readLearner(db, rules: rules)
            let terms = try Self.readTerms(db).filter { $0.state == .live }
            learner.learnAll(takes, terms: terms, common: common)
            if !writing.isEmpty {
                learner.noteWriting(writing)
                learner.refreshStates()
            }
            try Self.writeLearner(db, learner)
            return learner
        }
    }

    private static func readTerms(_ db: Database) throws -> [VocabularyTerm] {
        try String.fetchAll(db, sql: "SELECT body FROM vocab_term ORDER BY key").map { try decoder.decode(VocabularyTerm.self, from: Data($0.utf8)) }
    }

    private static func readLearner(_ db: Database, rules: HeardAsLearner.Rules) throws -> HeardAsLearner {
        let rows = try String.fetchAll(db, sql: "SELECT body FROM vocab_heard ORDER BY id")
        return HeardAsLearner(rules: rules, candidates: try rows.map { try decoder.decode(HeardAsLearner.Candidate.self, from: Data($0.utf8)) })
    }

    private static func writeLearner(_ db: Database, _ learner: HeardAsLearner) throws {
        try db.execute(sql: "DELETE FROM vocab_heard")
        for c in learner.all {
            try db.execute(
                sql: "INSERT INTO vocab_heard (id, formKey, termKey, state, hits, seen, body) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [c.id, c.formKey, c.termKey, c.state.rawValue, c.hits, c.seen, String(decoding: try encoder.encode(c), as: UTF8.self)])
        }
    }

    /// The system word list plus the ordinary words learned from the user's writing at build time.
    public func commonWords(system: CommonWords = .system()) throws -> CommonWords {
        let learned = try meta("ordinaryWords").map { $0.split(separator: "\n").map(String.init) } ?? []
        return CommonWords(system.words.union(learned))
    }

    public func meta(_ name: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT value FROM vocab_meta WHERE name = ?", arguments: [name]) }
    }

    public func setMeta(_ name: String, _ value: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO vocab_meta (name, value) VALUES (?, ?)", arguments: [name, value])
        }
    }
}
