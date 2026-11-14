import FluidAudio
import Foundation
import SaylarkCore

/// Speech to text for the streaming transcriber. `Recognizer` is the real one; tests pass fakes
/// (for example one that fails), so the transcriber and the engine run without the model.
public protocol SpeechTranscribing: Sendable {
    /// Transcribes 16 kHz mono samples; `timeOffset` is added to every timing.
    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> Transcript
    /// One short pass so the next real one doesn't pay first-use costs (launch, wake from sleep).
    func warmUp() async throws
}

/// Speech probability per `VoiceActivity.chunkSize` chunk. `VoiceActivity` is the real one.
public protocol VoiceDetecting: Sendable {
    func makeState() -> VadStreamState
    func probability(of chunk: [Float], state: inout VadStreamState) async throws -> Float
}

/// Parakeet on the Neural Engine, kept loaded. Wraps FluidAudio's `AsrManager` and returns Saylark
/// `Transcript`s.
///
/// `AsrManager` is an actor, but its `transcribe` awaits inside (preprocessor buffers, Core ML
/// predictions), so actor reentrancy lets two calls interleave on the one model. Every call here
/// goes through `gate`, a FIFO async lock, so live partials, closed windows and the tail really run
/// one at a time.
///
/// Models live in FluidAudio's default folder (`~/Library/Application Support/FluidAudio/Models`).
/// That path must stay fixed: the Neural Engine compile cache is keyed on it.
public struct Recognizer: Sendable {
    public static let sampleRate = 16_000
    static let sampleRateDouble = Double(sampleRate)

    let asr: AsrManager
    let decoderLayers: Int
    public let version: String
    let gate = AsyncGate()

    /// Downloads (first run only), loads and warms the model. `progress` gets download and compile
    /// states, then `.warming`; it is called on any thread.
    public static func load(ultra: Bool = true, progress: (@Sendable (ModelState) -> Void)? = nil) async throws -> Recognizer {
        let version: AsrModelVersion = ultra ? .ultra : .v3
        var handler: ProgressHandler?
        if let report = progress {
            handler = { @Sendable (p: DownloadProgress) -> Void in report(Self.modelState(p)) }
        }
        ModelPins.apply()
        let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: handler)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let recognizer = Recognizer(asr: asr, decoderLayers: await asr.decoderLayerCount, version: ultra ? "ultra" : "v3")
        progress?(.warming)
        try await recognizer.warmUp()
        return recognizer
    }

    static func modelState(_ p: DownloadProgress) -> ModelState {
        switch p.phase {
        case .listing: .downloading(progress: 0)
        case .downloading: .downloading(progress: p.fractionCompleted)
        case .compiling: .compiling(progress: p.fractionCompleted)
        }
    }

    /// One short transcription so the first real one doesn't pay first-use costs.
    public func warmUp() async throws {
        let asr = self.asr, layers = decoderLayers
        try await gate.run {
            var state = TdtDecoderState.make(decoderLayers: layers)
            _ = try await asr.transcribe([Float](repeating: 0.001, count: Self.sampleRate), decoderState: &state)
        }
    }

    /// A fresh decoder state, as at the start of a dictation.
    public func freshState() -> TdtDecoderState {
        TdtDecoderState.make(decoderLayers: decoderLayers)
    }

    /// Transcribes 16 kHz mono samples. Very short audio is padded to the model's minimum.
    /// `timeOffset` is added to every timing. Pass `state` to continue from an earlier window.
    public func transcribe(
        _ samples: [Float], timeOffset: Double = 0, state: TdtDecoderState? = nil
    ) async throws -> Recognition {
        var input = samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Self.sampleRate)
        if input.count < minimum { input += [Float](repeating: 0, count: minimum - input.count) }
        let initial = state ?? freshState(), asr = self.asr, audio = input
        let (result, decoderState) = try await gate.run { () async throws -> (ASRResult, TdtDecoderState) in
            var st = initial
            let r = try await asr.transcribe(audio, decoderState: &st)
            return (r, st)
        }
        let tokens = (result.tokenTimings ?? []).map {
            TranscriptToken(
                text: $0.token, start: $0.startTime + timeOffset, end: $0.endTime + timeOffset, confidence: $0.confidence, tokenId: $0.tokenId)
        }
        let transcript = Transcript(text: result.text, words: TranscriptToken.words(from: tokens), tokens: tokens)
        return Recognition(transcript: transcript, confidence: result.confidence, state: decoderState, raw: result)
    }
}

extension Recognizer: SpeechTranscribing {
    public func transcribe(_ samples: [Float], timeOffset: Double) async throws -> Transcript {
        try await transcribe(samples, timeOffset: timeOffset, state: nil).transcript
    }
}

/// A FIFO async lock: `run` bodies execute one at a time, in call order, without blocking a thread.
public actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// One transcription result. `state` and `raw` stay inside the engine.
public struct Recognition: Sendable {
    public let transcript: Transcript
    /// FluidAudio's whole-utterance confidence.
    public let confidence: Float
    let state: TdtDecoderState
    let raw: ASRResult
}
