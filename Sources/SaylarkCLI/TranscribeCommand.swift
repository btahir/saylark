import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark transcribe <file.wav>`: prints the text, or JSON with word and token timings.
enum TranscribeCommand {
    struct Output: Encodable {
        let file: String
        let model: String
        let duration: Double
        let loadMs: Double
        let latencyMs: Double
        let text: String
        let cleaned: String
        let confidence: Float
        let windows: [StreamingTranscriber.Window]?
        let words: [TranscriptWord]
        let tokens: [TranscriptToken]
    }

    static func run(_ args: Arguments) async throws {
        let path = try args.requirePositional(0, "file")
        let samples = try AudioFile.load(URL(fileURLWithPath: path))
        let loadStart = ContinuousClock.now
        let recognizer = try await Recognizer.load(ultra: !args.flag("v3"))
        let loadMs = loadStart.msSince

        var transcript: Transcript
        var windows: [StreamingTranscriber.Window]? = nil
        var confidence: Float = 0
        let began = ContinuousClock.now
        var latency: Double
        if args.flag("windowed") {
            let streaming = StreamingTranscriber(recognizer: recognizer, voice: try await VoiceActivity.load())
            let started = ContinuousClock.now
            for chunk in stride(from: 0, to: samples.count, by: 1600) {
                try await streaming.append(Array(samples[chunk..<min(samples.count, chunk + 1600)]))
            }
            let out = try await streaming.finish()
            latency = started.msSince
            transcript = out.transcript
            windows = out.windows
            confidence = transcript.words.map(\.confidence).min() ?? 0
        } else {
            let r = try await recognizer.transcribe(samples)
            latency = began.msSince
            transcript = r.transcript
            confidence = r.confidence
        }

        if args.flag("json") {
            let out = Output(
                file: path, model: recognizer.version, duration: Double(samples.count) / 16_000, loadMs: loadMs,
                latencyMs: latency, text: transcript.text, cleaned: Cleanup.apply(transcript.text), confidence: confidence,
                windows: windows, words: transcript.words, tokens: transcript.tokens)
            print(try jsonString(out))
        } else {
            print(transcript.text)
            log("\(fmt(Double(samples.count) / 16_000, 1)) s audio, \(fmt(latency)) ms, load \(fmt(loadMs)) ms")
        }
    }
}
