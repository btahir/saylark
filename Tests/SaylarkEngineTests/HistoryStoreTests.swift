import AVFoundation
import Foundation
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// History in a temp folder; the real Application Support folder is never touched.
@Suite struct HistoryStoreTests {
    static func tempFolder() -> URL {
        let base = ProcessInfo.processInfo.environment["SL_TEST_TMP"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
    }

    static func record(_ text: String, at t: Double, outcome: DictationOutcome = .logged, audio: String? = nil) -> DictationRecord {
        DictationRecord(
            startedAt: Date(timeIntervalSince1970: t), duration: 3, mode: .shadow, handsFree: false, appBundleID: "com.example.notes",
            appName: "Notes", rawText: text, cleanText: text, words: [TranscriptWord(text: "x", start: 0, end: 0.1, confidence: 0.9)],
            releaseToTextMs: 42, outcome: outcome, audioPath: audio)
    }

    @Test func savesListsAndSearches() async throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(folder: folder)
        let a = Self.record("Deploy the landing page tonight", at: 1000)
        let b = Self.record("Write the release notes", at: 2000)
        let c = Self.record("Check the deployment logs", at: 3000)
        for r in [a, b, c] { try await store.save(r, metrics: TakeMetrics(micStartMs: 12, windows: 1)) }

        let recent = try await store.recent(limit: 10, before: nil)
        #expect(recent.map(\.id) == [c.id, b.id, a.id])
        #expect(recent[0] == c)
        #expect(try await store.recent(limit: 10, before: Date(timeIntervalSince1970: 3000)).map(\.id) == [b.id, a.id])
        #expect(try await store.recent(limit: 1, before: nil).count == 1)

        // Prefix search: "depl" finds both deploy and deployment, newest first.
        #expect(try await store.search("depl", limit: 10).map(\.id) == [c.id, a.id])
        #expect(try await store.search("release notes", limit: 10).map(\.id) == [b.id])
        #expect(try await store.search("   ", limit: 10).isEmpty)
        #expect(try await store.metrics(for: a.id)?.micStartMs == 12)
    }

    /// Takes from the removed Shadow mode still read back, and an update keeps them intact.
    @Test func oldShadowTakesStillReadBack() async throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(folder: folder)
        var a = Self.record("ship it to worsel", at: 1000)
        a.mode = .shadow
        a.outcome = .logged
        try await store.save(a)
        #expect(try await store.record(a.id) == a)
        let updated = try await store.update(a.id) { r, _ in r.cleanText = "ship it to Vercel" }
        #expect(updated?.mode == .shadow && updated?.cleanText == "ship it to Vercel")
        #expect(try await store.search("vercel", limit: 5).map(\.id) == [a.id])
    }

    @Test func deleteRemovesAudio() async throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(folder: folder)
        let id = UUID()
        let path = AudioArchive.relativePath(id: id, startedAt: Date())
        try AudioArchive.writeM4A([Float](repeating: 0.1, count: 16_000), to: folder.appendingPathComponent(path))
        var r = Self.record("hello", at: 1000, audio: path)
        r.id = id
        try await store.save(r)
        #expect(store.audioURL(for: r) != nil)
        try await store.delete(id)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path))
        #expect(try await store.count() == 0)
        #expect(try await store.search("hello", limit: 5).isEmpty)
    }

    @Test func retentionPrunesAudioKeepsText() async throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(folder: folder)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        func make(_ text: String, daysAgo: Double, outcome: DictationOutcome = .logged) throws -> DictationRecord {
            let id = UUID()
            let path = "audio/test/\(id.uuidString).m4a"
            try AudioArchive.writeM4A([Float](repeating: 0.05, count: 1_600), to: folder.appendingPathComponent(path))
            var r = Self.record(text, at: now.timeIntervalSince1970 - daysAgo * 86_400, outcome: outcome, audio: path)
            r.id = id
            return r
        }
        let old = try make("old take", daysAgo: 20)
        let recent = try make("recent take", daysAgo: 2)
        let cancelled = try make("cancelled take", daysAgo: 2, outcome: .cancelled)
        for r in [old, recent, cancelled] { try await store.save(r) }

        #expect(try await store.pruneAudio(keepDays: 14, now: now) == 2)
        let all = try await store.recent(limit: 10, before: nil)
        #expect(all.count == 3)
        #expect(all.first { $0.id == recent.id }?.audioPath != nil)
        #expect(all.first { $0.id == old.id }?.audioPath == nil)
        #expect(all.first { $0.id == cancelled.id }?.audioPath == nil)
        // Forever keeps normal takes.
        #expect(try await store.pruneAudio(keepDays: nil, now: now.addingTimeInterval(400 * 86_400)) == 0)
    }

    @Test func m4aRoundTrip() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.m4a")
        let sine: [Float] = (0..<32_000).map { (i: Int) -> Float in
            let phase = Double(i) * 2 * Double.pi * 300 / 16_000
            return Float(0.3 * sin(phase))
        }
        try AudioArchive.writeM4A(sine, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(abs(Double(file.length) - 32_000) < 2_048)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size < 32_000)  // about 44 kbit/s plus the file header
    }
}
