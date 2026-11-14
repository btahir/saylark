import Foundation
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// Moving the old vocabulary store into `dictionary.txt`, and the engine reloading the file.
/// Temp folders only; the real Application Support folder is never touched.
@MainActor @Suite struct DictionaryMigrationTests {
    static func folder() -> URL {
        let base = ProcessInfo.processInfo.environment["SL_TEST_TMP"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("dictmig-\(UUID().uuidString)")
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A store with live, candidate and blocked terms and learned heard-as forms.
    static func legacyStore(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("vocabulary.sqlite")
        let store = try VocabularyStore(url: url)
        try store.update(now: now) { book in
            book.observe(TermObservation(spelling: "UTLDR", source: .history, count: 32, at: now))
            book.observe(TermObservation(spelling: "YouTLDR", source: .project, projects: ["youtldr"], at: now))
            book.observe(TermObservation(spelling: "Codex", source: .project, at: now))
            book.observe(TermObservation(spelling: "Kalshi", source: .history, at: now))  // a candidate
            book.observeLearned(spelling: "nviidia", heard: "the GPU", source: .wisprDictionary, count: 1, at: now)  // blocked
        }
        try store.learnAll([("we use codecs", "We use Codex.", now), ("codecs wrote it", "Codex wrote it.", now)])
        try store.setMeta("ordinaryWords", "reelbird\nshiptiffin")
        return url
    }

    @Test func movesLiveTermsAndTrustedFormsOnceAndNeverChangesTheStore() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = try Self.legacyStore(in: folder)
        let before = try Data(contentsOf: legacy)
        let dict = folder.appendingPathComponent("Saylark/dictionary.txt")

        let result = try #require(try DictionaryMigration.migrateIfNeeded(dictionary: dict, legacy: legacy, at: Self.now))
        #expect(result.terms == 2 && result.aliases == 2 && result.skipped.isEmpty)
        let file = try DictionaryFile.load(dict)
        #expect(file.entries == [DictionaryEntry(term: "Codex", aliases: ["codecs"]), DictionaryEntry(term: "YouTLDR", aliases: ["UTLDR"])])
        #expect(file.text.hasPrefix(DictionaryFile.header))
        #expect(try Data(contentsOf: legacy) == before)

        // Once the file exists it is the user's: never rewritten from the store.
        try DictionaryFile.update(dict) { _ = $0.remove("Codex") }
        #expect(try DictionaryMigration.migrateIfNeeded(dictionary: dict, legacy: legacy) == nil)
        #expect(try DictionaryFile.load(dict).entries.map(\.term) == ["YouTLDR"])
        #expect(DictionaryMigration.ordinaryWords(legacy: legacy) == ["reelbird", "shiptiffin"])
    }

    @Test func noOldStoreMeansNoFile() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dict = folder.appendingPathComponent("dictionary.txt")
        #expect(try DictionaryMigration.migrateIfNeeded(dictionary: dict, legacy: folder.appendingPathComponent("none.sqlite")) == nil)
        #expect(!FileManager.default.fileExists(atPath: dict.path))
        #expect(throws: (any Error).self) { try VocabularyStore(readingOnly: folder.appendingPathComponent("none.sqlite")) }
    }

    @Test func weakFormsAndUnwritableTermsStayBehind() {
        let at = Self.now
        var t = VocabularyTerm(spelling: "Reelbird", sources: [.history], sightings: 3, firstSeen: at, lastSeen: at, state: .live)
        t.aliases = [HeardAs(form: "real bird", count: 1, source: .history), HeardAs(form: "Realbird", count: 3, source: .history),
                     HeardAs(form: "reel bird", count: 1, source: .asr), HeardAs(form: "Reelbird", count: 9, source: .history)]
        let colon = VocabularyTerm(spelling: "a:b", sources: [.history], sightings: 3, firstSeen: at, lastSeen: at, state: .live)
        let candidate = VocabularyTerm(spelling: "Maybe", sources: [.history], sightings: 1, firstSeen: at, lastSeen: at)
        let (entries, skipped) = DictionaryMigration.entries(from: [t, colon, candidate])
        #expect(entries == [DictionaryEntry(term: "Reelbird", aliases: ["Realbird", "reel bird"])])
        #expect(skipped == ["a:b"])
    }

    // MARK: The engine

    /// The fake recogniser writes "w0 w1 …". A dictionary line turns them into a name; editing the
    /// file changes the next take without a restart, and a malformed line is skipped.
    @Test func engineLoadsTheDictionaryAndReloadsWhenTheFileChanges() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dict = folder.appendingPathComponent("dictionary.txt")
        let heard = (0..<12).map { "w\($0)" }.joined(separator: ", ")
        try DictionaryFile.parse("Banana: \(heard)\n").write(to: dict)
        let fn = ScriptedFnSource([(0.1, .fnDown), (2.0, .fnUp), (4.0, .fnDown), (6.0, .fnUp)])
        let rig = try ShadowEngineTests.rig(fn: fn, speech: FakeSpeech.samples(words: 0..<12), folder: folder) { parts in
            parts.dictionaryURL = dict
        }
        try await rig.engine.start()
        #expect(rig.engine.dictionaryStatus.entries == 1)
        await waitUntil(10) { !rig.log.saved.isEmpty }
        #expect(rig.log.saved.first?.cleanText.contains("Banana") == true)

        try Data("Mango: \(heard)\n: broken line\nKiwi\n".utf8).write(to: dict, options: .atomic)
        await waitUntil(3) { rig.engine.dictionaryStatus.entries == 2 }
        #expect(rig.engine.dictionaryStatus.entries == 2)
        #expect(rig.engine.dictionaryStatus.problems.map(\.line) == [2])
        let firstID = try #require(rig.log.saved.first?.id)
        await waitUntil(10) { rig.log.saved.contains { $0.id != firstID } }
        let second = try #require(rig.log.saved.first { $0.id != firstID })
        #expect(second.cleanText.contains("Mango") && !second.cleanText.contains("Banana"), "\(second.rawText) | \(second.cleanText)")

        try FileManager.default.removeItem(at: dict)
        await waitUntil(3) { rig.engine.dictionaryStatus.entries == 0 }
        #expect(rig.engine.dictionaryStatus.entries == 0)
        rig.engine.stop()
    }

    @Test func engineCreatesTheDictionaryFromTheOldStoreOnFirstStart() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = try Self.legacyStore(in: folder)
        let dict = folder.appendingPathComponent("dictionary.txt")
        let rig = try ShadowEngineTests.rig(fn: ScriptedFnSource([]), speech: [], folder: folder) { parts in
            parts.dictionaryURL = dict
            parts.legacyVocabularyURL = legacy
        }
        try await rig.engine.start()
        #expect(try DictionaryFile.load(dict).entries.map(\.term) == ["Codex", "YouTLDR"])
        #expect(rig.engine.dictionaryStatus.entries == 2)
        rig.engine.stop()
    }
}
