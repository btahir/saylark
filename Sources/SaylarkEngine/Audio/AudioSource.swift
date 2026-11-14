import Foundation
import SaylarkCore
import Synchronization

/// Why a source stopped on its own.
public enum AudioSourceFailure: Error, Sendable, Equatable {
    /// The device was unplugged or died mid-capture.
    case deviceLost(name: String)
    case startFailed(status: Int32, step: String)
}

/// A microphone, real or fake. Delivers mono Float32 at the source's own rate, on a worker queue
/// (never the real-time audio thread).
public protocol AudioSource: AnyObject, Sendable {
    var name: String { get }
    var sampleRate: Double { get }
    func start(onChunk: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (AudioSourceFailure) -> Void) throws
    /// Stops capture. Safe to call from any thread, including the source's own worker queue.
    func stop()
    /// Delivers any audio still buffered inside the source to `onChunk` before returning.
    func flush()
}

public extension AudioSource {
    func flush() {}
}

/// Plays a clip as if a mic were hearing it: chunks on a wall clock (or as fast as possible),
/// then silence while still "open". Used by tests and `saylark simulate`; opens no device.
public final class FakeAudioSource: AudioSource, @unchecked Sendable {
    public enum Pace: Sendable { case realtime, fast }

    public let name: String
    public let sampleRate: Double
    private let samples: [Float]
    private let chunk: Int
    private let pace: Pace
    /// Delay before the first chunk, like a real device's start-up time.
    private let startDelay: Double
    /// Simulates an unplug this many seconds after start.
    private let failAfter: Double?
    private let queue = DispatchQueue(label: "saylark.fake-mic", qos: .userInitiated)
    private let state = Mutex<(running: Bool, generation: Int, position: Int)>((false, 0, 0))

    /// `continuous`: the clip keeps playing across stops and starts, like a person still talking
    /// (position is kept); otherwise every start plays from the beginning.
    private let continuous: Bool

    public init(
        samples: [Float], sampleRate: Double = 16_000, chunkSeconds: Double = 0.01, pace: Pace = .realtime,
        startDelay: Double = 0, failAfter: Double? = nil, continuous: Bool = false, name: String = "Fake Mic"
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.chunk = max(1, Int(chunkSeconds * sampleRate))
        self.pace = pace
        self.startDelay = startDelay
        self.failAfter = failAfter
        self.continuous = continuous
        self.name = name
    }

    /// Samples delivered so far (the clip position).
    public var position: Int { state.withLock { $0.position } }

    public func start(onChunk: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (AudioSourceFailure) -> Void) throws {
        let generation = state.withLock { s -> Int in
            s.running = true
            s.generation += 1
            if !continuous { s.position = 0 }
            return s.generation
        }
        let began = DispatchTime.now()
        let chunkNanos = UInt64(Double(chunk) / sampleRate * 1e9)
        let delayNanos = UInt64(startDelay * 1e9)
        let samples = self.samples, chunk = self.chunk, pace = self.pace, rate = sampleRate, failAfter = self.failAfter, name = self.name
        queue.async { [self] in
            var k: UInt64 = 0
            while true {
                if pace == .realtime {
                    let due = began.uptimeNanoseconds + delayNanos + (k + 1) * chunkNanos
                    let now = DispatchTime.now().uptimeNanoseconds
                    if due > now { Thread.sleep(forTimeInterval: Double(due - now) / 1e9) }
                }
                let next: [Float]? = state.withLock { s in
                    guard s.running, s.generation == generation else { return nil }
                    let from = s.position
                    s.position += chunk
                    if from >= samples.count { return [Float](repeating: 0, count: chunk) }
                    let piece = Array(samples[from..<min(samples.count, from + chunk)])
                    return piece.count < chunk ? piece + [Float](repeating: 0, count: chunk - piece.count) : piece
                }
                guard let next else { return }
                onChunk(next)
                k += 1
                if let failAfter, Double(k) * Double(chunk) / rate >= failAfter {
                    state.withLock { $0.running = false }
                    onFailure(.deviceLost(name: name))
                    return
                }
                // Fast pace stops once the clip and a short tail are out, so runs end.
                if pace == .fast, state.withLock({ $0.position }) >= samples.count + Int(rate) { return }
            }
        }
    }

    public func stop() {
        state.withLock { $0.running = false }
    }
}
