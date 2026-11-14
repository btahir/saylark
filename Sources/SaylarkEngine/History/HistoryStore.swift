import Foundation
import GRDB
import SaylarkCore

/// Dictation history in SQLite (GRDB) with an FTS5 index over the clean text. (The `wispr*` columns
/// hold text from the removed Shadow mode; they are no longer read or written.)
/// Lives at `~/Library/Application Support/Saylark/history.sqlite`, audio under `audio/` next to it.
/// Tests pass a temp folder.
public final class HistoryStore: HistoryReading, Sendable {
    public let folder: URL
    private let db: DatabaseQueue

    /// The real app folder. Never used by tests.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Saylark", isDirectory: true)
    }

    public init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio", isDirectory: true), withIntermediateDirectories: true)
        // Transcripts and recordings: owner-only, whatever the umask.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var config = Configuration()
        config.label = "saylark.history"
        db = try DatabaseQueue(path: folder.appendingPathComponent("history.sqlite").path, configuration: config)
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "take") { t in
                t.column("id", .text).primaryKey()
                t.column("startedAt", .double).notNull().indexed()
                t.column("duration", .double).notNull()
                t.column("mode", .text).notNull()
                t.column("handsFree", .boolean).notNull()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("rawText", .text).notNull()
                t.column("cleanText", .text).notNull()
                t.column("words", .jsonText)
                t.column("releaseToTextMs", .double)
                t.column("outcome", .text).notNull()
                t.column("audioPath", .text)
                t.column("wisprText", .text)
                t.column("wisprLatencyMs", .double)
                t.column("wisprID", .text)
                /// Engine timings for this take (JSON `TakeMetrics`).
                t.column("metrics", .jsonText)
            }
            try db.create(virtualTable: "take_ft", using: FTS5()) { t in
                t.synchronize(withTable: "take")
                t.tokenizer = .unicode61()
                t.column("cleanText")
                t.column("wisprText")
            }
        }
        m.registerMigration("v2-recovered") { db in
            try db.alter(table: "take") { t in
                t.add(column: "recovered", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v3-sent") { db in
            try db.alter(table: "take") { t in
                t.add(column: "sent", .boolean).notNull().defaults(to: false)
            }
        }
        return m
    }

    // MARK: - Writing

    /// Inserts or replaces a record. `metrics` is stored alongside for diagnostics.
    public func save(_ record: DictationRecord, metrics: TakeMetrics? = nil) async throws {
        let row = TakeRow(record, metrics: metrics)
        try await db.write { db in try row.save(db) }
    }

    /// One record by id.
    public func record(_ id: UUID) async throws -> DictationRecord? {
        try await db.read { db in try TakeRow.fetchOne(db, key: id.uuidString)?.record }
    }

    public func metrics(for id: UUID) async throws -> TakeMetrics? {
        try await db.read { db in try TakeRow.fetchOne(db, key: id.uuidString)?.metrics }
    }

    /// Changes a saved record and its metrics in place. Returns the new
    /// record, or nil if there is no such take.
    @discardableResult
    public func update(_ id: UUID, _ change: @escaping @Sendable (inout DictationRecord, inout TakeMetrics?) -> Void) async throws -> DictationRecord? {
        try await db.write { db in
            guard let row = try TakeRow.fetchOne(db, key: id.uuidString) else { return nil }
            var record = row.record
            var metrics = row.metrics
            change(&record, &metrics)
            try TakeRow(record, metrics: metrics).save(db)
            return record
        }
    }

    /// Deletes audio past its retention: `keepDays` for normal takes (nil keeps forever), one day
    /// for cancelled takes. Text stays. Returns how many files were removed.
    @discardableResult
    public func pruneAudio(keepDays: Int?, now: Date = Date()) async throws -> Int {
        let normalCutoff = keepDays.map { now.addingTimeInterval(-Double($0) * 86_400).timeIntervalSince1970 }
        let cancelledCutoff = now.addingTimeInterval(-86_400).timeIntervalSince1970
        let folder = self.folder
        return try await db.write { db in
            var sql = "SELECT * FROM take WHERE audioPath IS NOT NULL AND ((outcome = 'cancelled' AND startedAt < ?)"
            var args: [any DatabaseValueConvertible] = [cancelledCutoff]
            if let normalCutoff { sql += " OR startedAt < ?"; args.append(normalCutoff) }
            sql += ")"
            let rows = try TakeRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            for var row in rows {
                if let path = row.audioPath { try? FileManager.default.removeItem(at: folder.appendingPathComponent(path)) }
                row.audioPath = nil
                try row.update(db)
            }
            return rows.count
        }
    }

    // MARK: - HistoryReading

    public func recent(limit: Int, before: Date?) async throws -> [DictationRecord] {
        try await db.read { db in
            let before = before?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            return try TakeRow.fetchAll(db, sql: "SELECT * FROM take WHERE startedAt < ? ORDER BY startedAt DESC LIMIT ?", arguments: [before, limit]).map(\.record)
        }
    }

    public func search(_ query: String, limit: Int) async throws -> [DictationRecord] {
        guard let words = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        // The clean text only: old Shadow takes also index the other app's text.
        let pattern = "cleanText : (\(words.rawPattern))"
        return try await db.read { db in
            try TakeRow.fetchAll(db, sql: """
                SELECT take.* FROM take JOIN take_ft ON take_ft.rowid = take.rowid AND take_ft MATCH ?
                ORDER BY take.startedAt DESC LIMIT ?
                """, arguments: [pattern, limit]).map(\.record)
        }
    }

    public func audioURL(for record: DictationRecord) -> URL? {
        guard let path = record.audioPath else { return nil }
        let url = folder.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func delete(_ id: UUID) async throws {
        let folder = self.folder
        try await db.write { db in
            if let row = try TakeRow.fetchOne(db, key: id.uuidString), let path = row.audioPath {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(path))
            }
            _ = try TakeRow.deleteOne(db, key: id.uuidString)
        }
    }

    public func count() async throws -> Int {
        try await db.read { db in try TakeRow.fetchCount(db) }
    }
}

/// Engine timings kept with each take (not part of the UI contract).
public struct TakeMetrics: Codable, Sendable, Equatable {
    /// Fn-down → first audio from the mic, ms (nil when the mic was warm).
    public var micStartMs: Double?
    public var preRollSeconds: Double = 0
    public var device: String?
    public var windows = 0
    public var partials = 0
    public var reusedPartial = false
    /// How Fn was heard: "tap", "monitor", "hid", "script".
    public var hook: String?
    /// Fn-down → the device open call returned, ms, off the main thread (nil when warm).
    public var micOpenMs: Double?
    /// Main-thread time spent starting the take at Fn-down, ms.
    public var beginMs: Double?
    /// Windows that failed twice (their words are missing; the take is `.failed`).
    public var failedWindows = 0
    /// Voice detection failed and the take fell back to fixed-length windows.
    public var voiceDetectionFailed = false
    /// Active mode: how the text went in, with its timings.
    public var insertion: InsertionMetrics?

    public init(micStartMs: Double? = nil, preRollSeconds: Double = 0, device: String? = nil, windows: Int = 0, partials: Int = 0, reusedPartial: Bool = false, hook: String? = nil) {
        self.micStartMs = micStartMs
        self.preRollSeconds = preRollSeconds
        self.device = device
        self.windows = windows
        self.partials = partials
        self.reusedPartial = reusedPartial
        self.hook = hook
    }

    private enum CodingKeys: String, CodingKey {
        case micStartMs, preRollSeconds, device, windows, partials, reusedPartial, hook, micOpenMs, beginMs, failedWindows, voiceDetectionFailed
        case insertion
    }

    /// Rows written before a field existed decode with its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        micStartMs = try c.decodeIfPresent(Double.self, forKey: .micStartMs)
        preRollSeconds = try c.decodeIfPresent(Double.self, forKey: .preRollSeconds) ?? 0
        device = try c.decodeIfPresent(String.self, forKey: .device)
        windows = try c.decodeIfPresent(Int.self, forKey: .windows) ?? 0
        partials = try c.decodeIfPresent(Int.self, forKey: .partials) ?? 0
        reusedPartial = try c.decodeIfPresent(Bool.self, forKey: .reusedPartial) ?? false
        hook = try c.decodeIfPresent(String.self, forKey: .hook)
        micOpenMs = try c.decodeIfPresent(Double.self, forKey: .micOpenMs)
        beginMs = try c.decodeIfPresent(Double.self, forKey: .beginMs)
        failedWindows = try c.decodeIfPresent(Int.self, forKey: .failedWindows) ?? 0
        voiceDetectionFailed = try c.decodeIfPresent(Bool.self, forKey: .voiceDetectionFailed) ?? false
        insertion = try c.decodeIfPresent(InsertionMetrics.self, forKey: .insertion)
    }
}

/// Active mode's account of one take's insertion. Times are milliseconds.
public struct InsertionMetrics: Codable, Sendable, Equatable {
    /// "pasted", "accessibility", "card:<reason>", "empty".
    public var outcome: String
    /// Release → final text (the Shadow-mode `releaseToTextMs`).
    public var textMs: Double?
    /// Release → ⌘V posted (or the card decided). The record's `releaseToTextMs` in Active mode.
    public var releaseToPasteMs: Double?
    /// `insert` called → ⌘V posted (includes the focus probe at release).
    public var insertCallMs: Double?
    /// From the settlement, ms after the `insert` call: ⌘V posted, first read, clipboard restored.
    public var keyMs: Double?
    public var firstReadMs: Double?
    public var restoreMs: Double?
    public var readConfirmed: Bool?
    /// What became of the user's clipboard ("restored", "leftExternalChange", …).
    public var clipboard: String?
    public var viaCard: Bool?
    /// Dictate and send: the Return interceptor was armed for this take.
    public var returnArmed: Bool?
    /// Return ended the take.
    public var sendRequested: Bool?
    /// ⌘V posted → the target's read seen (send path).
    public var readWaitMs: Double?
    /// Release → Return posted.
    public var releaseToReturnMs: Double?
    public var sendSkipped: String?

    public init(outcome: String) { self.outcome = outcome }
}

/// One row of the `take` table.
struct TakeRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "take"

    var id: String
    var startedAt: Double
    var duration: Double
    var mode: String
    var handsFree: Bool
    var appBundleID: String?
    var appName: String?
    var rawText: String
    var cleanText: String
    var words: [TranscriptWord]?
    var releaseToTextMs: Double?
    var outcome: String
    var audioPath: String?
    var metrics: TakeMetrics?
    var recovered: Bool
    var sent: Bool

    init(_ r: DictationRecord, metrics: TakeMetrics?) {
        id = r.id.uuidString
        startedAt = r.startedAt.timeIntervalSince1970
        duration = r.duration
        mode = r.mode.rawValue
        handsFree = r.handsFree
        appBundleID = r.appBundleID
        appName = r.appName
        rawText = r.rawText
        cleanText = r.cleanText
        words = r.words
        releaseToTextMs = r.releaseToTextMs
        outcome = r.outcome.rawValue
        audioPath = r.audioPath
        self.metrics = metrics
        recovered = r.recovered
        sent = r.sent
    }

    var record: DictationRecord {
        var r = DictationRecord(
            id: UUID(uuidString: id) ?? UUID(), startedAt: Date(timeIntervalSince1970: startedAt), duration: duration,
            mode: DictationMode(rawValue: mode) ?? .shadow, handsFree: handsFree, appBundleID: appBundleID, appName: appName,
            rawText: rawText, cleanText: cleanText, words: words ?? [], releaseToTextMs: releaseToTextMs,
            outcome: DictationOutcome(rawValue: outcome) ?? .logged, audioPath: audioPath, recovered: recovered)
        r.sent = sent
        return r
    }
}
