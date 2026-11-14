import AVFoundation
import Foundation
import SaylarkCore
import Synchronization

/// Owns the microphone for takes. Opens it at Fn-down (default) or keeps it warm with a 450 ms
/// pre-roll ring, converts to 16 kHz mono, and routes each take's audio and 120 Hz levels to a
/// sink. The source is injected, so tests and `saylark simulate` run with a fake mic.
///
/// Threads: opening and closing the device (device enumeration, AUHAL start and stop) run on a
/// private serial `control` queue, never on the caller's thread, so Fn-down on the main thread
/// never waits for Core Audio. Audio arrives on the source's worker queue. A source failure (an
/// unplug) is reported from that worker queue; the source is stopped from `control`, never from
/// the worker itself (stopping syncs onto the worker, which would trap).
///
/// Capture keeps no copy of the take: the sink gets every sample once, in order.
public final class Capture: @unchecked Sendable {
    public struct Config: Sendable {
        /// Keep the mic open between takes ("Keep mic ready"). The orange dot stays on.
        public var keepWarm = false
        /// Audio from before Fn-down added to a take when the mic was warm.
        public var preRoll: Double = 0.45
        public var levelRate: Double = 120

        public init() {}
    }

    /// Where a take's audio goes. Called on the capture worker queue, in order.
    public struct Sink: Sendable {
        public var audio: @Sendable ([Float]) -> Void
        public var levels: @Sendable ([VoiceLevel]) -> Void
        public var failed: @Sendable (AudioSourceFailure) -> Void

        public init(audio: @escaping @Sendable ([Float]) -> Void, levels: @escaping @Sendable ([VoiceLevel]) -> Void, failed: @escaping @Sendable (AudioSourceFailure) -> Void) {
            self.audio = audio
            self.levels = levels
            self.failed = failed
        }
    }

    /// How one take's audio went. The samples themselves went to the sink.
    public struct TakeAudio: Sendable {
        /// Samples delivered to the sink (16 kHz), pre-roll included.
        public var sampleCount: Int
        /// Fn-down → first audio from the device, ms. Nil when the mic was already warm (or no audio
        /// arrived).
        public var micStartMs: Double?
        /// Fn-down → the device open call returned, ms (nil when warm). Runs off the main thread.
        public var micOpenMs: Double?
        public var preRollSeconds: Double
        public var deviceName: String

        public var duration: Double { Double(sampleCount) / Double(Recognizer.sampleRate) }
    }

    private struct State {
        var config: Config
        var source: (any AudioSource)?
        /// An open is queued or running on `control`.
        var opening = false
        var resampler: Resampler?
        /// The rate `resampler` converts from (0 = none needed yet).
        var resamplerRate: Double = 0
        var sink: Sink?
        var delivered = 0
        var meter = VoiceLevelMeter()
        var ring: PreRollRing
        var startRequested: Double?
        var micStartMs: Double?
        var micOpenMs: Double?
        var preRollSeconds: Double = 0
        var deviceName = ""
        /// Devices changed during a take: re-pick the warm mic once it ends.
        var repickPending = false
    }

    private let makeSource: @Sendable () throws -> any AudioSource
    private let state: Mutex<State>
    private let control = DispatchQueue(label: "saylark.capture.control", qos: .userInitiated)
    private static let rate = Double(Recognizer.sampleRate)

    /// `makeSource` is called whenever the mic opens (on the control queue), so it can pick the
    /// device at that moment.
    public init(config: Config = Config(), makeSource: @escaping @Sendable () throws -> any AudioSource) {
        self.makeSource = makeSource
        state = Mutex(State(config: config, ring: PreRollRing(capacity: Int(config.preRoll * Self.rate))))
    }

    public var isOpen: Bool { state.withLock { $0.source != nil } }

    /// Waits until queued opens and closes have run. For tests and the CLI.
    public func settle() {
        control.sync {}
    }

    /// Turns "Keep mic ready" on or off. On opens the mic (in the background); off closes it if no
    /// take is running.
    public func setKeepWarm(_ on: Bool) {
        let (open, close) = state.withLock { s -> (Bool, Bool) in
            s.config.keepWarm = on
            return (on, !on && s.sink == nil)
        }
        if open { requestOpen() } else if close { requestClose() }
    }

    /// Closes and reopens a warm mic between takes, so the policy picks the device again (after a
    /// hot-plug or a wake). Does nothing during a take or when the mic is not kept warm.
    public func repick() {
        let now = state.withLock { s -> Bool in
            guard s.config.keepWarm else { return false }
            if s.sink != nil { s.repickPending = true; return false }
            return true
        }
        guard now else { return }
        requestClose(force: true)
        // Queued behind the close, so the open sees the old source gone.
        control.async { [self] in requestOpen() }
    }

    /// Starts a take. With a warm mic the pre-roll goes to the sink first. A cold mic is opened in
    /// the background; if that fails, `sink.failed` is called. Returns at once.
    public func beginTake(_ sink: Sink, now: Double = HotkeyClock.now) {
        let needsOpen = state.withLock { s -> Bool in
            s.sink = sink
            s.delivered = 0
            s.meter = VoiceLevelMeter(sampleRate: Self.rate, rate: s.config.levelRate)
            s.micStartMs = nil
            s.micOpenMs = nil
            s.preRollSeconds = 0
            if s.source != nil {
                let pre = s.ring.latest(Int(s.config.preRoll * Self.rate))
                s.preRollSeconds = Double(pre.count) / Self.rate
                if !pre.isEmpty { deliver(pre, in: &s) }
                s.startRequested = nil
                return false
            }
            s.startRequested = now
            return true
        }
        if needsOpen { requestOpen(requestedAt: now) }
    }

    /// Ends the take. Audio still buffered in the device is delivered to the sink first. Closes the
    /// mic (in the background) unless it is kept warm.
    @discardableResult
    public func endTake() -> TakeAudio {
        let source = state.withLock { $0.source }
        source?.flush()
        let (audio, close, repick) = state.withLock { s -> (TakeAudio, Bool, Bool) in
            let a = TakeAudio(sampleCount: s.delivered, micStartMs: s.micStartMs, micOpenMs: s.micOpenMs, preRollSeconds: s.preRollSeconds, deviceName: s.source?.name ?? s.deviceName)
            s.sink = nil
            s.startRequested = nil
            defer { s.repickPending = false }
            return (a, !s.config.keepWarm, s.repickPending && s.config.keepWarm)
        }
        if close { requestClose() } else if repick { self.repick() }
        return audio
    }

    /// Ends the take only if the mic has delivered nothing to it (it never opened). Returns whether
    /// it did.
    public func endTakeIfSilent() -> Bool {
        let (ended, close) = state.withLock { s -> (Bool, Bool) in
            guard s.sink != nil, s.delivered == 0 else { return (false, false) }
            s.sink = nil
            s.startRequested = nil
            return (true, !s.config.keepWarm)
        }
        if close { requestClose() }
        return ended
    }

    // MARK: - Source (control queue)

    private func requestOpen(requestedAt: Double? = nil) {
        let queue = state.withLock { s -> Bool in
            guard s.source == nil, !s.opening else { return false }
            s.opening = true
            return true
        }
        guard queue else { return }
        control.async { [self] in openNow(requestedAt: requestedAt) }
    }

    /// `force`: close even though the mic is kept warm (a re-pick reopens it right after).
    private func requestClose(force: Bool = false) {
        control.async { [self] in
            // A take or keep-warm may have asked for the mic again since this close was queued.
            let source = state.withLock { s -> (any AudioSource)? in
                guard s.sink == nil, force || !s.config.keepWarm else { return nil }
                defer { s.source = nil; s.resampler = nil; s.resamplerRate = 0; s.ring.clear() }
                return s.source
            }
            source?.stop()
        }
    }

    private func openNow(requestedAt: Double?) {
        let wanted = state.withLock { s -> Bool in
            if s.sink == nil && !s.config.keepWarm { s.opening = false; return false }
            return true
        }
        guard wanted else { return }
        let source: any AudioSource
        do {
            source = try makeSource()
            state.withLock { $0.source = source; $0.resampler = nil; $0.resamplerRate = 0; $0.ring.clear(); $0.deviceName = source.name }
            try source.start(
                onChunk: { [weak self] chunk in self?.received(chunk) },
                onFailure: { [weak self] failure in self?.failed(failure) })
        } catch {
            let sink = state.withLock { s -> Sink? in
                s.source = nil
                s.opening = false
                return s.sink
            }
            let failure = error as? AudioSourceFailure ?? .startFailed(status: -1, step: String(describing: error))
            sink?.failed(failure)
            return
        }
        let stillWanted = state.withLock { s -> Bool in
            s.opening = false
            if let requestedAt, s.sink != nil, s.micOpenMs == nil { s.micOpenMs = (HotkeyClock.now - requestedAt) * 1000 }
            return s.sink != nil || s.config.keepWarm
        }
        if !stillWanted { requestClose() }
    }

    private func received(_ raw: [Float]) {
        let now = HotkeyClock.now
        let resamplerFailed = state.withLock { s -> Bool in
            // The device rate is only certain once the source has started (AUHAL reads the hardware
            // format then), so the resampler is built from the rate at the first chunk, and rebuilt
            // if the rate ever changes.
            let from = s.source?.sampleRate ?? Self.rate
            if from != Self.rate, from != s.resamplerRate {
                s.resampler = Resampler(from: from, to: Self.rate)
                s.resamplerRate = from
                if s.resampler == nil { return true }
            } else if from == Self.rate, s.resampler != nil {
                s.resampler = nil
                s.resamplerRate = 0
            }
            let chunk = s.resampler?.convert(raw) ?? raw
            if let requested = s.startRequested {
                s.micStartMs = (now - requested) * 1000
                s.startRequested = nil
            }
            s.ring.add(chunk)
            if s.sink != nil { deliver(chunk, in: &s) }
            return false
        }
        if resamplerFailed { failed(.startFailed(status: -1, step: "resampler")) }
    }

    private func deliver(_ chunk: [Float], in s: inout State) {
        s.delivered += chunk.count
        s.sink?.audio(chunk)
        let levels = s.meter.add(chunk)
        if !levels.isEmpty { s.sink?.levels(levels) }
    }

    /// Called on the source's worker queue. The source is stopped on `control`, never here.
    private func failed(_ failure: AudioSourceFailure) {
        let (sink, source) = state.withLock { s -> (Sink?, (any AudioSource)?) in
            defer { s.source = nil; s.resampler = nil; s.resamplerRate = 0; s.ring.clear() }
            return (s.sink, s.source)
        }
        if let source { control.async { source.stop() } }
        sink?.failed(failure)
    }
}

/// Device rate → 16 kHz mono with AVAudioConverter, one chunk at a time. Used only from the
/// capture worker queue.
final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let ratio: Double

    init?(from: Double, to: Double) {
        guard from > 0, let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        self.input = input
        self.output = output
        self.converter = converter
        self.ratio = to / from
    }

    func convert(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, let inBuf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var given = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
