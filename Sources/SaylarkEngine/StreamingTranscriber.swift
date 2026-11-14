import FluidAudio
import Foundation
import SaylarkCore

/// Transcribes one dictation while it is being spoken. Audio arrives in chunks; Silero voice
/// detection closes a window at the first pause after about 10 s (hard cut at 14 s), and each
/// closed window is transcribed in the background. `finish()` then only has the tail left.
///
/// Live words: every `partialInterval` seconds of new audio, and at each pause, the open window is
/// transcribed again and `onWords` gets every word so far. At release, if no speech came after the
/// newest partial, that partial is the tail and no transcription is needed.
///
/// One instance per dictation. Feed audio with `enqueue(_:)` from a capture callback (it never
/// blocks) or with `append(_:)` from async code; use one or the other, not both.
///
/// Never loses a take: a window whose transcription fails is tried once more from its audio, and
/// if that fails too it is left empty and counted in `Output.failedWindows` (the engine then saves
/// the take as `.failed` with its audio). A voice-detection failure is retried once; after that
/// the rest of the take is cut at the hard-cut length instead of at pauses.
///
/// Memory: only the open window plus `maxCarry` is kept (about 15 s), not the whole take. The
/// whole take's audio lives in the engine's spool file.
public actor StreamingTranscriber {
    public struct Config: Sendable, Equatable {
        public var planner = WindowPlanner.Config()
        /// A word ending this close to a cut (seconds) is dropped from its window and heard again
        /// at the start of the next one. Off by default: on the 80 eval clips 0.1 s and 0.2 s
        /// changed WER by +0.1 and +0.3 points.
        public var boundaryMargin: Double = 0
        /// Priority of window and tail transcriptions.
        public var priority: TaskPriority = .userInitiated
        /// Never re-hear more than this much audio (seconds) from the previous window.
        public var maxCarry: Double = 1
        /// Re-transcribe the open window after this much new audio (seconds). 0 turns partials off.
        public var partialInterval: Double = 0
        /// Also re-transcribe at the start of each pause (at least `minPartialGap` after the last).
        public var partialOnPause = true
        public var minPartialGap: Double = 0.3
        /// Use the newest partial as the tail when nothing but silence came after it.
        public var reuseAtRelease = true
        /// Audio after the last voice-detection chunk counts as silence when every 20 ms frame's
        /// RMS is below this (dBFS).
        public var releaseSilenceDB: Float = -42

        public init() {}

        /// Partials every 0.8 s and at pauses, reused at release.
        public static var live: Config {
            var c = Config()
            c.partialInterval = 0.8
            return c
        }
    }

    /// Partial and release statistics for one dictation.
    public struct LiveStats: Codable, Sendable {
        public var partials = 0
        public var partialMs: [Double] = []
        /// The tail was the newest partial (no transcription at release).
        public var reusedAtRelease = false
        /// Release waited this long for a partial that was running.
        public var waitedForPartialMs: Double = 0
        /// Diagnostics, seconds: where the newest partial ended, the last speech chunk ended, and
        /// the audio ended.
        public var lastPartialEnd: Double?
        public var lastSpeechEnd: Double = 0
        public var audioEnd: Double = 0
    }

    /// What happened to one window, for logs and benchmarks.
    public struct Window: Codable, Sendable {
        public var start: Double
        public let end: Double
        public let isHardCut: Bool
        public let isTail: Bool
        public var transcribeMs: Double = 0
        public var text = ""
    }

    public struct Output: Sendable {
        public let transcript: Transcript
        public let windows: [Window]
        public var live = LiveStats()
        /// Windows that failed twice and were left empty. Nonzero means words are missing.
        public var failedWindows = 0
        /// Voice detection failed and the take fell back to fixed-length windows.
        public var voiceDetectionFailed = false
    }

    /// The newest transcription of the open window.
    private struct Partial: Sendable {
        let start: Int
        let end: Int
        let transcript: Transcript
    }

    private struct WindowResult: Sendable {
        let transcript: Transcript
        /// First sample this window actually transcribed.
        let from: Int
        /// Where the next window should start.
        let nextStart: Int
        let ms: Double
        var failed = false
    }

    private let recognizer: any SpeechTranscribing
    private let voice: any VoiceDetecting
    private let config: Config
    private let rate = Double(Recognizer.sampleRate)

    /// The audio still needed: absolute samples `base..<total`.
    private var buffer: [Float] = []
    private var base = 0
    private var total: Int { base + buffer.count }
    private var vadCursor = 0
    private var vadState: VadStreamState
    private var vadRunning = false
    private var vadFailed = false
    private var planner: WindowPlanner
    private var tasks: [Task<WindowResult, Never>] = []
    private var windows: [Window] = []
    private var finished = false

    // Live words
    private var onWords: (@Sendable ([String]) -> Void)?
    private var partial: Partial?
    private var partialTask: Task<Partial?, Never>?
    private var lastPartialAt = 0
    private var lastSpeechEnd = 0
    private var previousWasSpeech = false
    /// Per closed window: its final transcript once done, else the last partial seen for it.
    private var shown: [Transcript] = []
    private var pendingWindows = 0
    private var stats = LiveStats()

    private let input: AsyncStream<[Float]>.Continuation
    private let stream: AsyncStream<[Float]>
    private var pumpDone = false
    private var pumpWaiters: [CheckedContinuation<Void, Never>] = []

    public init(recognizer: any SpeechTranscribing, voice: any VoiceDetecting, config: Config = Config(), onWords: (@Sendable ([String]) -> Void)? = nil) {
        self.onWords = onWords
        self.recognizer = recognizer
        self.voice = voice
        self.config = config
        self.planner = WindowPlanner(config: config.planner)
        self.vadState = voice.makeState()
        (stream, input) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        Task { await self.pump() }
    }

    // MARK: - Input

    /// Queues a chunk of 16 kHz mono audio. Safe to call from any thread; never waits.
    public nonisolated func enqueue(_ chunk: [Float]) {
        input.yield(chunk)
    }

    /// Adds a chunk of 16 kHz mono audio and runs voice detection on it.
    public func append(_ chunk: [Float]) async throws {
        precondition(!finished, "append after finish")
        buffer += chunk
        await runVoiceDetection()
    }

    private func pump() async {
        for await chunk in stream {
            guard !finished else { continue }
            buffer += chunk
            await runVoiceDetection()
        }
        pumpDone = true
        pumpWaiters.forEach { $0.resume() }
        pumpWaiters = []
    }

    private func waitForPump() async {
        if pumpDone { return }
        await withCheckedContinuation { pumpWaiters.append($0) }
    }

    /// Runs Silero on every complete 256 ms chunk not yet seen, closing windows as the planner says.
    /// Re-entrant calls return at once: the running loop picks up the new samples.
    private func runVoiceDetection() async {
        guard !vadRunning else { return }
        vadRunning = true
        defer { vadRunning = false }
        let size = VoiceActivity.chunkSize
        while total - vadCursor >= size, !finished {
            let start = vadCursor
            let p = await speechProbability(of: slice(start, start + size))
            vadCursor = start + size
            let speech = p >= config.planner.silenceThreshold
            if speech { lastSpeechEnd = vadCursor }
            if let cut = planner.observe(start: start, end: start + size, probability: p) {
                let at = QuietPoint.find(in: buffer, range: (cut.range.lowerBound - base)..<(cut.range.upperBound - base)) + base
                closeWindow(at: at, isHardCut: cut.isHardCut, isTail: false)
                planner.didCut(at: at)
                trim()
            } else {
                maybeStartPartial(pauseBegan: previousWasSpeech && !speech)
            }
            previousWasSpeech = speech
        }
    }

    /// Silero's speech probability for one chunk, retried once. If it fails twice, voice detection
    /// is off for the rest of the take: every chunk counts as speech, so windows close at the hard
    /// cut (at the quietest frame near it) and nothing is lost.
    private func speechProbability(of chunk: [Float]) async -> Float {
        guard !vadFailed else { return 1 }
        for _ in 0..<2 {
            var state = vadState
            if let p = try? await voice.probability(of: chunk, state: &state) {
                vadState = state
                return p
            }
        }
        vadFailed = true
        return 1
    }

    /// Samples `from..<to` (absolute indices).
    private func slice(_ from: Int, _ to: Int) -> [Float] {
        Array(buffer[(from - base)..<(to - base)])
    }

    /// Drops audio no window will need again: everything before the open window's carry.
    private func trim() {
        let keepFrom = max(0, planner.windowStart - Int(config.maxCarry * rate))
        let drop = min(keepFrom, vadCursor) - base
        guard drop >= Int(rate) else { return }
        buffer.removeFirst(drop)
        base += drop
    }

    // MARK: - Partials

    private func maybeStartPartial(pauseBegan: Bool) {
        guard config.partialInterval > 0, onWords != nil || config.reuseAtRelease, !finished else { return }
        // Never compete with a closed window: it is on the release path.
        guard partialTask == nil, pendingWindows == 0 else { return }
        let since = vadCursor - lastPartialAt
        let due = since >= Int(config.partialInterval * rate)
            || (config.partialOnPause && pauseBegan && since >= Int(config.minPartialGap * rate))
        guard due, lastSpeechEnd > planner.windowStart else { return }
        let start = planner.windowStart, end = vadCursor
        guard end - start >= Int(0.3 * rate) else { return }
        lastPartialAt = end
        let snapshot = slice(start, end)
        let recognizer = self.recognizer
        partialTask = Task(priority: config.priority) { [weak self] in
            let began = ContinuousClock.now
            guard let r = try? await recognizer.transcribe(snapshot, timeOffset: Double(start) / Recognizer.sampleRateDouble) else { return nil }
            let result = Partial(start: start, end: end, transcript: r)
            await self?.partialDone(result, ms: began.duration(to: .now).milliseconds)
            return result
        }
    }

    private func partialDone(_ p: Partial, ms: Double) {
        partialTask = nil
        stats.partials += 1
        stats.partialMs.append(ms)
        // A cut since it started means this partial straddles two windows: drop it.
        guard p.start == planner.windowStart else { return }
        partial = p
        emitWords()
    }

    private func windowDone(_ index: Int, _ transcript: Transcript?) {
        pendingWindows -= 1
        if let transcript, index < shown.count { shown[index] = transcript }
        emitWords()
    }

    private func emitWords() {
        guard let onWords, !finished else { return }
        var words = shown.flatMap(\.words).map(\.text)
        if let partial, partial.start == planner.windowStart { words += partial.transcript.words.map(\.text) }
        onWords(words)
    }

    /// True when nothing that could be speech arrived after `end`.
    private func silentAfter(_ end: Int) -> Bool {
        guard lastSpeechEnd <= end else { return false }
        let from = max(end, vadCursor)
        guard from < total else { return true }
        let frame = 320
        var i = from
        let gate = pow(10, config.releaseSilenceDB / 20)
        while i < total {
            let j = min(total, i + frame)
            var sum: Float = 0
            for k in (i - base)..<(j - base) { sum += buffer[k] * buffer[k] }
            if (sum / Float(j - i)).squareRoot() >= gate { return false }
            i = j
        }
        return true
    }

    // MARK: - Windows

    /// Queues a window ending at `end`. It starts where the previous window said to start: that is
    /// the planned cut, unless the previous window's last word touched the cut, in which case that
    /// word is dropped there and heard again, whole, at the start of this window.
    private func closeWindow(at end: Int, isHardCut: Bool, isTail: Bool) {
        let planned = planner.windowStart
        let lookback = max(base, planned - Int(config.maxCarry * rate))
        let snapshot = slice(lookback, max(lookback, end))
        let previous = tasks.last
        let recognizer = self.recognizer
        let margin = config.boundaryMargin, maxCarry = config.maxCarry, rate = self.rate
        tasks.append(Task(priority: config.priority) {
            let from = max(lookback, await previous?.value.nextStart ?? planned)
            guard end - from >= Int(0.05 * rate) else {
                return WindowResult(transcript: .empty, from: from, nextStart: max(from, end), ms: 0)
            }
            let began = ContinuousClock.now
            let audio = Array(snapshot[(from - lookback)...])
            // One retry from the same audio: a Neural Engine hiccup must not cost the window.
            var heard = try? await recognizer.transcribe(audio, timeOffset: Double(from) / rate)
            if heard == nil, !Task.isCancelled { heard = try? await recognizer.transcribe(audio, timeOffset: Double(from) / rate) }
            guard var transcript = heard else {
                return WindowResult(transcript: .empty, from: from, nextStart: end, ms: began.duration(to: .now).milliseconds, failed: true)
            }
            var next = end
            if !isTail, margin > 0 {
                let cut = Double(end) / rate
                var kept = transcript.words
                while let last = kept.last, last.end > cut - margin, cut - last.start < maxCarry { kept.removeLast() }
                if kept.count < transcript.words.count {
                    let redo = transcript.words[kept.count].start
                    let floor = kept.last.map { Int($0.end * rate) } ?? from
                    next = min(end, max(floor, Int((redo - 0.04) * rate)))
                    transcript = Transcript(
                        text: kept.map(\.text).joined(separator: " "), words: kept,
                        tokens: transcript.tokens.filter { $0.start < redo })
                }
            }
            return WindowResult(transcript: transcript, from: from, nextStart: next, ms: began.duration(to: .now).milliseconds)
        })
        windows.append(Window(start: Double(planned) / rate, end: Double(end) / rate, isHardCut: isHardCut, isTail: isTail))
        if !isTail {
            // Until the window's own result lands, show its newest partial so words don't vanish.
            shown.append(partial?.start == planned ? partial!.transcript : .empty)
            partial = nil
            lastPartialAt = end
            pendingWindows += 1
            let index = shown.count - 1, task = tasks[tasks.count - 1]
            Task { [weak self] in
                let r = await task.value
                await self?.windowDone(index, r.failed ? nil : r.transcript)
            }
        }
    }

    /// Queues the tail as an already-finished window holding the newest partial.
    private func reusePartialAsTail(_ p: Partial) {
        let lookback = p.start
        tasks.append(Task { () -> WindowResult in WindowResult(transcript: p.transcript, from: lookback, nextStart: p.end, ms: 0) })
        windows.append(Window(start: Double(p.start) / rate, end: Double(total) / rate, isHardCut: false, isTail: true))
    }

    /// Waits until every closed window has been transcribed. For tests and simulated benchmarks.
    public func waitForWindows() async {
        for task in tasks { _ = await task.value }
    }

    /// Ends the dictation: transcribes the tail and returns the joined text of all windows. Never
    /// throws: failed windows are reported in `Output.failedWindows`.
    public func finish() async -> Output {
        input.finish()
        await waitForPump()
        if let running = partialTask {
            let began = ContinuousClock.now
            _ = await running.value
            stats.waitedForPartialMs = began.duration(to: .now).milliseconds
        }
        finished = true
        stats.lastPartialEnd = partial.map { Double($0.end) / rate }
        stats.lastSpeechEnd = Double(lastSpeechEnd) / rate
        stats.audioEnd = Double(total) / rate
        if config.reuseAtRelease, let p = partial, p.start == planner.windowStart, silentAfter(p.end) {
            stats.reusedAtRelease = true
            reusePartialAsTail(p)
        } else {
            closeWindow(at: total, isHardCut: false, isTail: true)
        }
        var parts: [Transcript] = []
        var failedWindows = 0
        for (i, task) in tasks.enumerated() {
            let r = await task.value
            parts.append(r.transcript)
            if r.failed { failedWindows += 1 }
            windows[i].transcribeMs = r.ms
            windows[i].start = Double(r.from) / rate
            windows[i].text = r.transcript.text
        }
        tasks = []
        buffer = []
        return Output(transcript: .joined(parts), windows: windows, live: stats, failedWindows: failedWindows, voiceDetectionFailed: vadFailed)
    }

    /// Drops the dictation. Running windows are cancelled.
    public func cancel() {
        finished = true
        input.finish()
        tasks.forEach { $0.cancel() }
        partialTask?.cancel()
    }

    /// Seconds of audio received so far.
    public var duration: Double { Double(total) / rate }

    /// Samples held in memory now (the open window and its carry), for tests and diagnostics.
    public var bufferedSamples: Int { buffer.count }
}

extension Duration {
    var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
