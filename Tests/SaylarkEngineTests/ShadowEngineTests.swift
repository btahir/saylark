import Foundation
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// The whole engine with a scripted Fn key, the fake mic, a fake recognizer and a temp history.
/// No device, no key hook, no model.
@MainActor @Suite struct ShadowEngineTests {
    @MainActor final class EventLog {
        var events: [DictationEvent] = []
        var saved: [DictationRecord] { events.compactMap { if case .saved(let r) = $0 { r } else { nil } } }
        var pills: [(PillEvent, UUID?)] { events.compactMap { if case .pill(let e, let t) = $0, !Self.isWords(e) { (e, t) } else { nil } } }
        static func isWords(_ e: PillEvent) -> Bool { if case .words = e { true } else { false } }
    }

    struct Rig {
        let engine: ShadowEngine
        let folder: URL
        let log: EventLog
        var spoolFiles: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: TakeSpool.folder(in: folder).path)) ?? []
        }
    }

    static func rig(
        fn: ScriptedFnSource, speech: [Float], failAfter: Double? = nil, recognizer: FakeRecognizer = FakeRecognizer(),
        folder: URL? = nil, configure: (inout ShadowEngine.Parts) -> Void = { _ in }
    ) throws -> Rig {
        let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("saylark-engine-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")!
        let mic = FakeAudioSource(samples: speech, pace: .realtime, startDelay: 0.02, failAfter: failAfter, name: "Fake Q2U")
        let voice = FakeVoice()
        var parts = ShadowEngine.Parts(
            makeFnSource: { fn }, makeAudioSource: { mic }, historyFolder: folder, defaults: defaults,
            frontmostApp: { ("com.example.test", "Test") },
            loadModels: { _ in (recognizer, voice) })
        parts.fnCheckInterval = 0.2
        configure(&parts)
        let engine = try ShadowEngine(parts: parts)
        let log = EventLog()
        Task { @MainActor in for await e in engine.events { log.events.append(e) } }
        return Rig(engine: engine, folder: folder, log: log)
    }

    static let speech = FakeSpeech.samples(words: 0..<8)  // about 3.6 s
    static var speechSeconds: Double { Double(speech.count) / 16_000 }

    @Test func holdSavesTheTakeWithItsAudioAndTakeIDs() async throws {
        let rig = try Self.rig(fn: .hold(at: 0.1, for: Self.speechSeconds + 0.2), speech: Self.speech)
        try await rig.engine.start()
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .inserted)
        #expect(r.rawText == FakeSpeech.text(0..<8))
        #expect(rig.engine.store.audioURL(for: r) != nil)
        // Every pill event of the take carries its id.
        let pills = rig.log.pills
        #expect(pills.map(\.0) == [.listen, .finish(.inserted)])
        #expect(pills.allSatisfy { $0.1 == r.id })
        #expect(rig.spoolFiles.isEmpty)  // the spool is removed once the take is in history
        rig.engine.stop()
    }

    /// An unplug mid-take ends the take and keeps what was said before it.
    @Test func unplugMidTakeKeepsWhatWasSaid() async throws {
        let rig = try Self.rig(fn: .hold(at: 0.1, for: Self.speechSeconds + 0.2), speech: Self.speech, failAfter: 2.0)
        try await rig.engine.start()
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .inserted)
        #expect(r.rawText.hasPrefix("w0 w1"))
        #expect(abs(r.duration - 2.0) < 0.3)
        #expect(rig.engine.store.audioURL(for: r) != nil)
        #expect(rig.log.pills.contains { $0.0 == .fail(.microphoneMissing(name: "Fake Q2U")) && $0.1 == r.id })
        rig.engine.stop()
    }

    /// Before: a failed window made `finish()` throw and the take (audio too) was never saved.
    @Test func recognitionFailureSavesTheAudioAsFailed() async throws {
        let rig = try Self.rig(fn: .hold(at: 0.1, for: Self.speechSeconds + 0.2), speech: Self.speech, recognizer: FakeRecognizer { _, _ in true })
        try await rig.engine.start()
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .failed)
        #expect(r.duration > 3)
        #expect(rig.engine.store.audioURL(for: r) != nil)
        #expect(rig.log.pills.contains { $0.0 == .fail(.transcriptionFailed) && $0.1 == r.id })
        #expect(try await rig.engine.store.record(r.id)?.outcome == .failed)
        rig.engine.stop()
    }

    /// The Library can transcribe a failed take again from its saved audio.
    @Test func failedTakeCanBeTranscribedAgain() async throws {
        let flaky = FakeRecognizer { call, _ in call < 1000 }
        let rig = try Self.rig(fn: .hold(at: 0.1, for: Self.speechSeconds + 0.2), speech: Self.speech, recognizer: flaky)
        try await rig.engine.start()
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .failed)
        flaky.calls.withLock { $0 = 1000 }  // the model works again
        let again = try await rig.engine.retranscribe(r.id)
        #expect(again.outcome == .logged)
        #expect(again.rawText == FakeSpeech.text(0..<8))
        rig.engine.stop()
    }

    /// "Pause for 1 hour" calls `stop()`. A take running then is finished and saved, not dropped.
    @Test func stopDuringATakeSavesIt() async throws {
        let rig = try Self.rig(fn: .handsFree(at: 0.1, talk: 30), speech: Self.speech)
        try await rig.engine.start()
        try await Task.sleep(for: .seconds(Self.speechSeconds + 0.4))
        rig.engine.stop()
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .logged)
        #expect(r.handsFree)
        #expect(r.rawText == FakeSpeech.text(0..<8))
    }

    /// While the take runs its audio is on disk, at most a second behind.
    @Test func audioIsSpooledDuringTheTake() async throws {
        let rig = try Self.rig(fn: .hold(at: 0.1, for: Self.speechSeconds + 0.2), speech: Self.speech)
        try await rig.engine.start()
        try await Task.sleep(for: .seconds(2.6))
        let spool = TakeSpool.folder(in: rig.folder)
        let pcm = try #require(rig.spoolFiles.first { $0.hasSuffix(".pcm") })
        let size = try FileManager.default.attributesOfItem(atPath: spool.appendingPathComponent(pcm).path)[.size] as? Int ?? 0
        #expect(size >= 16_000 * 4)  // at least 1 s of Float32 audio already written
        #expect(rig.spoolFiles.contains { $0.hasSuffix(".json") })
        await waitUntil(10) { !rig.log.saved.isEmpty }
        #expect(rig.spoolFiles.isEmpty)
        rig.engine.stop()
    }

    /// A spool left by a crash is transcribed and saved at the next start, marked recovered.
    @Test func orphanedSpoolIsRecoveredAtStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saylark-engine-\(UUID().uuidString)")
        let id = UUID()
        let started = Date(timeIntervalSinceNow: -600)
        let spool = try TakeSpool(folder: TakeSpool.folder(in: folder), meta: .init(id: id, startedAt: started, mode: .shadow, handsFree: true, appBundleID: "com.example.crashed", appName: "Crashed"))
        let speech = FakeSpeech.samples(words: 0..<30)
        var i = 0
        while i < speech.count { spool.append(Array(speech[i..<min(speech.count, i + 160)])); i += 160 }
        await spool.close()  // the process "crashed" here: no record was saved

        let rig = try Self.rig(fn: ScriptedFnSource([]), speech: [], folder: folder)
        try await rig.engine.start()
        await rig.engine.waitForRecovery()
        let r = try #require(try await rig.engine.store.record(id))
        #expect(r.recovered)
        #expect(r.outcome == .logged)
        #expect(r.handsFree)
        #expect(r.appName == "Crashed")
        #expect(abs(r.startedAt.timeIntervalSince(started)) < 1)
        #expect(r.rawText == FakeSpeech.text(0..<30))
        #expect(rig.engine.store.audioURL(for: r) != nil)
        #expect(rig.spoolFiles.isEmpty)
        #expect(rig.log.saved.contains { $0.id == id })
        rig.engine.stop()
    }

    /// The hook misses the Fn release. The slow Fn check sees the key is up and ends the take,
    /// and the next press works.
    @Test func lostFnReleaseDoesNotLeaveTheTakeStuck() async throws {
        let fn = ScriptedFnSource([(0.1, .fnDown), (1.5, .fnUpLost), (2.6, .fnDown), (3.4, .fnUp)])
        let rig = try Self.rig(fn: fn, speech: FakeSpeech.samples(words: 0..<12))
        try await rig.engine.start()
        await waitUntil(10) { rig.log.saved.count >= 2 }
        let saved = rig.log.saved
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.outcome == .inserted })
        // The first take ended within one check of the lost release, not at the next press.
        #expect(saved.first.map { $0.duration < 1.9 } == true)
        rig.engine.stop()
    }

    /// A tap re-enable or rebuild reports the real Fn state; a lost release is replayed.
    @Test func resyncAfterTapRepairReplaysALostRelease() async throws {
        // Checks at 0.6 s (sees Fn down, so the reported state is trusted), 1.1 s, 1.6 s.
        let fn = ScriptedFnSource([(0.1, .fnDown), (1.2, .fnUpLost), (1.25, .resync)])
        let rig = try Self.rig(fn: fn, speech: Self.speech) { $0.fnCheckInterval = 0.5 }
        try await rig.engine.start()
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.duration < 1.4)
        rig.engine.stop()
    }

    /// If the system never reports Fn as down, its "up" is not trusted: a resync can't cut a real hold.
    @Test func untrustedFnStateNeverEndsAHold() async throws {
        let rig = try Self.rig(fn: ScriptedFnSource([]), speech: Self.speech) { $0.fnCheckInterval = 0 }
        try await rig.engine.start()
        rig.engine.handle(.fn(down: true, otherModifiers: false, time: HotkeyClock.now))
        try await Task.sleep(for: .seconds(1))
        rig.engine.handle(.fnState(down: false, time: HotkeyClock.now))
        try await Task.sleep(for: .seconds(0.5))
        #expect(rig.log.saved.isEmpty)
        rig.engine.handle(.fn(down: false, otherModifiers: false, time: HotkeyClock.now))
        await waitUntil(10) { !rig.log.saved.isEmpty }
        #expect(rig.log.saved.first.map { $0.duration > 1.3 } == true)
        rig.engine.stop()
    }

    /// Release-to-text counts from the Fn-up event's own timestamp, so main-thread delay before the
    /// event is handled shows up in the metric.
    @Test func releaseToTextCountsFromTheEventTimestamp() async throws {
        let rig = try Self.rig(fn: ScriptedFnSource([]), speech: Self.speech)
        try await rig.engine.start()
        rig.engine.handle(.fn(down: true, otherModifiers: false, time: HotkeyClock.now))
        try await Task.sleep(for: .seconds(1.5))
        rig.engine.handle(.fn(down: false, otherModifiers: false, time: HotkeyClock.now - 0.4))
        await waitUntil(10) { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect((r.releaseToTextMs ?? 0) >= 400)
        rig.engine.stop()
    }

    @Test func wakeRewarmsTheModel() async throws {
        let recognizer = FakeRecognizer()
        let rig = try Self.rig(fn: ScriptedFnSource([]), speech: [], recognizer: recognizer)
        try await rig.engine.start()
        rig.engine.didWake()
        await waitUntil(5) { recognizer.warmUps.withLock { $0 } > 0 }
        #expect(recognizer.warmUps.withLock { $0 } == 1)
        rig.engine.stop()
    }
}
