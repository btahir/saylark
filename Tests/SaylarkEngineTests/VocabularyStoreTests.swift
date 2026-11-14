import Foundation
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// The vocabulary store in a temp folder; the real Application Support folder is never touched.
@Suite struct VocabularyStoreTests {
    static func tempURL() -> URL {
        let base = ProcessInfo.processInfo.environment["SL_TEST_TMP"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("vocab-\(UUID().uuidString)/vocabulary.sqlite")
    }

    @Test func roundTripsAndUpdates() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = try VocabularyStore(url: url)
        let saved = try store.update(now: now) { book in
            book.observe(TermObservation(spelling: "UTLDR", source: .history, count: 32, at: now))
            book.observe(TermObservation(spelling: "YouTLDR", source: .project, projects: ["youtldr"], at: now))
            book.observe(TermObservation(spelling: "Kalshi", source: .history, at: now))
            book.observeLearned(spelling: "nviidia", heard: "the GPU", source: .wisprDictionary, count: 1, at: now)
        }
        let reopened = try VocabularyStore(url: url).load()
        #expect(reopened == saved)
        #expect(try store.liveTerms().map(\.spelling) == ["YouTLDR"])
        #expect(reopened.term("YouTLDR")?.aliases.first?.form == "UTLDR")
        #expect(reopened.term("Kalshi")?.state == .candidate)
        #expect(reopened.term("nviidia")?.state == .blocked)
        try store.setMeta("builtAt", "x")
        #expect(try store.meta("builtAt") == "x")
    }

    @Test func learnedFormsGoLiveAndSurviveARebuild() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = try VocabularyStore(url: url)
        try store.update(now: now) { book in
            book.observe(TermObservation(spelling: "Codex", source: .project, at: now))
        }
        try store.learnAll([("we use codecs", "We use Codex.", now), ("codecs wrote it", "Codex wrote it.", now)])
        #expect(try store.liveTerms().first?.aliases.map(\.form) == ["codecs"])
        // A rebuild replaces the terms, not the learned forms.
        try store.update(now: now) { book in book = VocabularyBook(terms: book.terms) }
        #expect(try store.heardAs().live.count == 1)
    }

    @Test func correctorSwapsWithoutTheCTCModel() async throws {
        let now = Date()
        let term = VocabularyTerm(
            spelling: "YouTLDR", aliases: [HeardAs(form: "UTLDR", count: 30, source: .history)], sources: [.project],
            sightings: 31, firstSeen: now, lastSeen: now, state: .live)
        var config = VocabularyCorrector.Config()
        config.mode = .swap
        let corrector = try await VocabularyCorrector.load(terms: [term], common: CommonWords(["use", "the"]), config: config)
        let words = [
            TranscriptWord(text: "use", start: 1.0, end: 1.2, confidence: 0.9),
            TranscriptWord(text: "UTLDR.", start: 1.2, end: 1.8, confidence: 0.7),
        ]
        let r = await corrector.correct(Transcript(text: "use UTLDR.", words: words), samples: [], timeOffset: 1.0)
        #expect(r.transcript.text == "use YouTLDR.")
        #expect(r.changes.count == 1)
        #expect(r.ctcMs == 0)
        // Mode off is a no-op.
        config.mode = .off
        let off = try await corrector.with(config: config)
        #expect(await off.correct(Transcript(text: "use UTLDR.", words: words), samples: []).transcript.text == "use UTLDR.")
    }
}
