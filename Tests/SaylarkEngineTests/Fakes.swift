import FluidAudio
import Foundation
import Synchronization
@testable import SaylarkCore
@testable import SaylarkEngine

/// Synthetic "speech" the fakes understand: word `k` is 0.3 s of a 400 Hz tone with amplitude
/// 0.1 + 0.01·k, words are 0.15 s apart, and every `perPhrase` words there is a 0.6 s pause (long
/// enough for the window planner to cut there). A tone, not a constant level, so it survives the
/// AAC round trip through the saved m4a.
enum FakeSpeech {
    static let rate = 16_000

    static func amplitude(_ k: Int) -> Float { 0.1 + 0.01 * Float(k) }

    static func samples(words: Range<Int>, perPhrase: Int = 5, lead: Double = 0.3) -> [Float] {
        var out = [Float](repeating: 0, count: Int(lead * Double(rate)))
        for (i, k) in words.enumerated() {
            let a = amplitude(k)
            out += (0..<Int(0.3 * Double(rate))).map { a * Float(sin(2 * Double.pi * 400 * Double($0) / Double(rate))) }
            let gap = (i + 1) % perPhrase == 0 ? 0.6 : 0.15
            out += [Float](repeating: 0, count: Int(gap * Double(rate)))
        }
        return out
    }

    static func text(_ words: Range<Int>) -> String { words.map { "w\($0)" }.joined(separator: " ") }

    /// Decodes runs of loud 10 ms frames (4 tone periods each) back into words.
    static func decode(_ samples: [Float]) -> [String] {
        let frame = 160
        var words: [String] = []
        var run: [Float] = []
        func close() {
            if run.count >= 5 {
                let peak = run.sorted()[run.count / 2]
                words.append("w\(Int(((peak - 0.1) / 0.01).rounded()))")
            }
            run = []
        }
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            let peak = (sum / Float(frame)).squareRoot() * Float(2).squareRoot()
            if peak > 0.05 { run.append(peak) } else { close() }
            i += frame
        }
        close()
        return words
    }
}

struct FakeASRError: Error {}

/// Transcribes `FakeSpeech` exactly. `fail` decides per call (call index, words heard) whether to
/// throw instead, to simulate Neural Engine errors.
final class FakeRecognizer: SpeechTranscribing, @unchecked Sendable {
    let calls = Mutex(0)
    let warmUps = Mutex(0)
    let fail: @Sendable (Int, [String]) -> Bool
    let delay: Duration

    init(delay: Duration = .milliseconds(2), fail: @escaping @Sendable (Int, [String]) -> Bool = { _, _ in false }) {
        self.fail = fail
        self.delay = delay
    }

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> Transcript {
        let n = calls.withLock { c -> Int in defer { c += 1 }; return c }
        try await Task.sleep(for: delay)
        let words = FakeSpeech.decode(samples)
        if fail(n, words) { throw FakeASRError() }
        let tw = words.enumerated().map { TranscriptWord(text: $1, start: timeOffset + Double($0), end: timeOffset + Double($0) + 0.3, confidence: 0.9) }
        return Transcript(text: words.joined(separator: " "), words: tw)
    }

    func warmUp() async throws { warmUps.withLock { $0 += 1 } }
}

/// Energy-based voice detection. `failFrom`: every call from this index on throws.
final class FakeVoice: VoiceDetecting, @unchecked Sendable {
    let calls = Mutex(0)
    let failFrom: Int?

    init(failFrom: Int? = nil) { self.failFrom = failFrom }

    func makeState() -> VadStreamState { VadStreamState.initial() }

    func probability(of chunk: [Float], state: inout VadStreamState) async throws -> Float {
        let n = calls.withLock { c -> Int in defer { c += 1 }; return c }
        if let failFrom, n >= failFrom { throw FakeASRError() }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count))).squareRoot()
        return rms > 0.02 ? 0.95 : 0.02
    }
}

/// Polls until `done` or the timeout.
func waitUntil(_ timeout: Double = 5, isolation: isolated (any Actor)? = #isolation, _ done: () async -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while await !done(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
}
