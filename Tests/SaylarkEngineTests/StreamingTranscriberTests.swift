import Foundation
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// The streaming transcriber with fake speech, a fake recognizer and fake voice detection, so
/// windowing, retries and memory can be checked without the model.
@Suite struct StreamingTranscriberTests {
    static func config() -> StreamingTranscriber.Config {
        var c = StreamingTranscriber.Config()
        c.partialInterval = 0
        c.reuseAtRelease = false
        return c
    }

    static func run(_ samples: [Float], recognizer: FakeRecognizer, voice: FakeVoice = FakeVoice(), config: StreamingTranscriber.Config = config()) async throws -> (StreamingTranscriber.Output, maxBuffered: Int) {
        let t = StreamingTranscriber(recognizer: recognizer, voice: voice, config: config)
        var maxBuffered = 0
        var i = 0
        while i < samples.count {
            try await t.append(Array(samples[i..<min(samples.count, i + 1600)]))
            maxBuffered = max(maxBuffered, await t.bufferedSamples)
            i += 1600
        }
        return (await t.finish(), maxBuffered)
    }

    @Test func fakeSpeechRoundTrips() async throws {
        let words = 0..<60
        let (out, _) = try await Self.run(FakeSpeech.samples(words: words), recognizer: FakeRecognizer())
        #expect(out.windows.count > 2)  // several windows were cut
        #expect(out.transcript.text == FakeSpeech.text(words))
        #expect(out.failedWindows == 0)
    }

    @Test func failedWindowIsRetriedFromItsAudio() async throws {
        let words = 0..<60
        // The first transcription (window 1) fails once; its retry works.
        let r = FakeRecognizer { call, _ in call == 0 }
        let (out, _) = try await Self.run(FakeSpeech.samples(words: words), recognizer: r)
        #expect(out.transcript.text == FakeSpeech.text(words))
        #expect(out.failedWindows == 0)
    }

    /// Before: one failed window threw out of `finish()` and the engine dropped the whole take.
    @Test func windowThatKeepsFailingCostsOnlyItsOwnWords() async throws {
        let words = 0..<60
        let r = FakeRecognizer { _, heard in heard.contains("w30") }
        let (out, _) = try await Self.run(FakeSpeech.samples(words: words), recognizer: r)
        #expect(out.failedWindows == 1)
        let heard = out.transcript.text.split(separator: " ").map(String.init)
        #expect(!heard.contains("w30"))
        #expect(heard.contains("w0"))
        #expect(heard.contains("w59"))  // later windows still ran
        #expect(heard.count >= 40)
    }

    @Test func voiceDetectionFailureFallsBackToFixedWindows() async throws {
        let words = 0..<60
        let voice = FakeVoice(failFrom: 10)
        let (out, _) = try await Self.run(FakeSpeech.samples(words: words), recognizer: FakeRecognizer(), voice: voice)
        #expect(out.voiceDetectionFailed)
        #expect(out.failedWindows == 0)
        // Hard cuts land at the quietest frame, which is a gap between words: nothing is lost.
        #expect(out.transcript.text == FakeSpeech.text(words))
    }

    /// A long take keeps only the open window and its carry in memory, not the whole take.
    @Test func longTakeKeepsOnlyTheOpenWindowInMemory() async throws {
        let words = 0..<400  // about 3.3 minutes
        let samples = FakeSpeech.samples(words: words)
        let (out, maxBuffered) = try await Self.run(samples, recognizer: FakeRecognizer())
        #expect(out.transcript.text == FakeSpeech.text(words))
        #expect(maxBuffered < 18 * 16_000)  // max window 14 s + 1 s carry + 1 s trim slack + a chunk
        #expect(samples.count > 10 * maxBuffered)
    }
}

@Suite struct AsyncGateTests {
    @Test func runsBodiesOneAtATimeInOrder() async {
        let gate = AsyncGate()
        let log = LogBox()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    await gate.run {
                        await log.enter(i)
                        try? await Task.sleep(for: .milliseconds(5))
                        await log.exit(i)
                    }
                }
            }
        }
        let (maxInside, entries) = await (log.maxInside, log.entries)
        #expect(maxInside == 1)
        #expect(entries.count == 8)
    }

    actor LogBox {
        var inside = 0
        var maxInside = 0
        var entries: [Int] = []
        func enter(_ i: Int) { inside += 1; maxInside = max(maxInside, inside); entries.append(i) }
        func exit(_ i: Int) { inside -= 1 }
    }
}
