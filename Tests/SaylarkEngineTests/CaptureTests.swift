import Foundation
import Synchronization
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// Capture with the fake mic: no device is ever opened.
@Suite struct CaptureTests {
    final class Collected: @unchecked Sendable {
        let audio = Mutex<[Float]>([])
        let levels = Mutex<[VoiceLevel]>([])
        let failures = Mutex<[AudioSourceFailure]>([])

        var sink: Capture.Sink {
            Capture.Sink(
                audio: { c in self.audio.withLock { $0 += c } },
                levels: { l in self.levels.withLock { $0 += l } },
                failed: { f in self.failures.withLock { $0.append(f) } })
        }
    }

    static func ramp(_ n: Int) -> [Float] { (0..<n).map { Float($0 % 1000) / 1000 } }


    @Test func coldTakeOpensAtFnDownAndCloses() async throws {
        let clip = Self.ramp(16_000)
        let source = FakeAudioSource(samples: clip, pace: .fast)
        let capture = Capture(makeSource: { source })
        let got = Collected()
        capture.beginTake(got.sink)
        capture.settle()
        #expect(capture.isOpen)
        await waitUntil { got.audio.withLock { $0.count } >= 16_000 }
        let take = capture.endTake()
        capture.settle()
        #expect(!capture.isOpen)
        let audio = got.audio.withLock { $0 }
        #expect(take.sampleCount == audio.count)
        #expect(Array(audio.prefix(16_000)) == clip)
        #expect(take.micStartMs != nil)
        #expect(take.micOpenMs != nil)
        #expect(take.preRollSeconds == 0)
        // 120 levels per second of audio.
        let levels = got.levels.withLock { $0 }
        #expect(abs(Double(levels.count) - Double(audio.count) / 16_000 * 120) <= 1)
    }

    @Test func warmMicAddsPreRoll() async throws {
        let clip = (0..<64_000).map { Float($0) }
        let source = FakeAudioSource(samples: clip, pace: .realtime, continuous: true)
        let capture = Capture(makeSource: { source })
        capture.setKeepWarm(true)
        await waitUntil { source.position >= 9_600 }
        let got = Collected()
        capture.beginTake(got.sink)
        #expect(got.audio.withLock { $0.count } == 7_200)  // 450 ms at 16 kHz, delivered at once
        await waitUntil { got.audio.withLock { $0.count } >= 9_000 }
        let take = capture.endTake()
        capture.settle()
        #expect(take.preRollSeconds == 0.45)
        #expect(take.micStartMs == nil)
        #expect(capture.isOpen)  // stays warm
        // Pre-roll joins the live audio with no gap or repeat.
        let audio = got.audio.withLock { $0 }
        let first = Int(audio[0])
        #expect(audio == Array(clip[first..<(first + audio.count)]))
        capture.setKeepWarm(false)
        capture.settle()
        #expect(!capture.isOpen)
    }

    @Test func unplugReportsDeviceLost() async throws {
        let source = FakeAudioSource(samples: Self.ramp(16_000), pace: .fast, failAfter: 0.2, name: "Samson Q2U Microphone")
        let capture = Capture(makeSource: { source })
        let got = Collected()
        capture.beginTake(got.sink)
        await waitUntil { !got.failures.withLock { $0.isEmpty } }
        #expect(got.failures.withLock { $0 } == [.deviceLost(name: "Samson Q2U Microphone")])
        #expect(!capture.isOpen)
        let take = capture.endTake()
        #expect(take.sampleCount == 3_200)  // the audio before the unplug is kept
        #expect(got.audio.withLock { $0.count } == 3_200)
    }

    /// The real mic reports an unplug from its own worker queue, and its `stop()` syncs onto that
    /// queue (`HALAudioSource`). Stopping it from inside the failure callback traps in libdispatch
    /// and kills the app. This source behaves the same way but records the reentrant stop instead
    /// of trapping.
    @Test func unplugReportedFromTheSourceQueueNeverStopsItThere() async throws {
        let source = QueueBoundSource(failAfterChunks: 20)
        let capture = Capture(makeSource: { source })
        let got = Collected()
        capture.beginTake(got.sink)
        await waitUntil { !got.failures.withLock { $0.isEmpty } }
        capture.settle()
        #expect(got.failures.withLock { $0 } == [.deviceLost(name: "Queue Mic")])
        #expect(source.stoppedOnOwnQueue.withLock { $0 } == false)
        #expect(source.stops.withLock { $0 } == 1)
        #expect(!capture.isOpen)
        let take = capture.endTake()
        #expect(take.sampleCount == 20 * 160)
    }

    /// AUHAL only knows the hardware rate once it has started. The resampler must use that rate,
    /// not the one the device reported before start.
    @Test func resamplerUsesTheRateKnownAfterStart() async throws {
        let source = RateChangingSource(before: 16_000, after: 48_000)
        let capture = Capture(makeSource: { source })
        let got = Collected()
        capture.beginTake(got.sink)
        await waitUntil { source.delivered.withLock { $0 } >= 48_000 }
        capture.endTake()
        capture.settle()
        let n = got.audio.withLock { $0.count }
        #expect(abs(n - 16_000) < 400, "got \(n) samples for 1 s of 48 kHz audio")
    }

    /// Opening a cold mic (device enumeration, AUHAL start) must not run on the caller's thread:
    /// Fn-down is handled on the main thread.
    @Test func coldOpenDoesNotBlockTheCaller() async throws {
        let clip = Self.ramp(16_000)
        let capture = Capture(makeSource: {
            Thread.sleep(forTimeInterval: 0.25)  // a slow Bluetooth open
            return FakeAudioSource(samples: clip, pace: .fast)
        })
        let got = Collected()
        let began = Date()
        capture.beginTake(got.sink)
        #expect(Date().timeIntervalSince(began) < 0.05)
        await waitUntil { got.audio.withLock { $0.count } >= 16_000 }
        let take = capture.endTake()
        #expect(take.micStartMs ?? 0 >= 250)
        #expect(Array(got.audio.withLock { $0 }.prefix(16_000)) == clip)
    }

    /// Hot-plug with "Keep mic ready" on: the warm mic is picked again between takes, and a change
    /// during a take is applied once the take ends.
    @Test func warmMicIsRepickedOnDeviceChanges() async throws {
        let opened = Mutex<[String]>([])
        let capture = Capture(makeSource: {
            let n = opened.withLock { o -> Int in o.append("mic\(o.count)"); return o.count }
            return FakeAudioSource(samples: Self.ramp(1_600), pace: .realtime, name: "mic\(n - 1)")
        })
        capture.setKeepWarm(true)
        capture.settle()
        #expect(opened.withLock { $0.count } == 1)
        capture.repick()
        capture.settle()
        capture.settle()
        #expect(opened.withLock { $0.count } == 2)
        #expect(capture.isOpen)
        let got = Collected()
        capture.beginTake(got.sink)
        capture.repick()  // during a take: deferred
        capture.settle()
        #expect(opened.withLock { $0.count } == 2)
        capture.endTake()
        capture.settle()
        capture.settle()
        #expect(opened.withLock { $0.count } == 3)
        #expect(capture.isOpen)
        capture.setKeepWarm(false)
        capture.settle()
        #expect(!capture.isOpen)
    }

    /// Ending a take before the slow open finished must not leave the mic open.
    @Test func takeEndedDuringOpenClosesTheMic() async throws {
        let clip = Self.ramp(16_000)
        let capture = Capture(makeSource: {
            Thread.sleep(forTimeInterval: 0.1)
            return FakeAudioSource(samples: clip, pace: .realtime)
        })
        capture.beginTake(Collected().sink)
        capture.endTake()
        capture.settle()
        capture.settle()
        #expect(!capture.isOpen)
    }

    @Test func resamples48kTo16k() {
        let r = Resampler(from: 48_000, to: 16_000)!
        let sine = (0..<48_000).map { Float(0.5 * sin(Double($0) * 2 * .pi * 440 / 48_000)) }
        var out: [Float] = []
        for k in stride(from: 0, to: sine.count, by: 480) { out += r.convert(Array(sine[k..<(k + 480)])) }
        #expect(abs(out.count - 16_000) <= 64)
        let peak = out.dropFirst(100).map(abs).max() ?? 0
        #expect(abs(peak - 0.5) < 0.05)
    }

    @Test func sampleRingDrainsInOrderAndDropsOldest() {
        let ring = SampleRing(capacity: 8)
        var a: [Float] = [1, 2, 3]
        ring.write(&a, count: 3)
        #expect(ring.drain() == [1, 2, 3])
        var b: [Float] = Array(stride(from: 4, through: 15, by: 1))
        ring.write(&b, count: b.count)
        #expect(ring.drain() == Array(stride(from: 8, through: 15, by: 1)))
        #expect(ring.drain().isEmpty)
    }
}

/// A mic like `HALAudioSource`: chunks and failures come from its own serial queue, and `stop()`
/// syncs onto that queue. A stop called on the queue itself is recorded (the real one traps).
final class QueueBoundSource: AudioSource, @unchecked Sendable {
    let name = "Queue Mic"
    let sampleRate: Double = 16_000
    let stoppedOnOwnQueue = Mutex(false)
    let stops = Mutex(0)
    private let failAfterChunks: Int
    private let queue = DispatchQueue(label: "test.queue-mic")
    private let key = DispatchSpecificKey<Bool>()
    private let running = Mutex(false)

    init(failAfterChunks: Int) {
        self.failAfterChunks = failAfterChunks
        queue.setSpecific(key: key, value: true)
    }

    func start(onChunk: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (AudioSourceFailure) -> Void) throws {
        running.withLock { $0 = true }
        let n = failAfterChunks
        queue.async { [self] in
            for _ in 0..<n {
                guard running.withLock({ $0 }) else { return }
                onChunk([Float](repeating: 0.01, count: 160))
            }
            onFailure(.deviceLost(name: name))
        }
    }

    func stop() {
        stops.withLock { $0 += 1 }
        running.withLock { $0 = false }
        if DispatchQueue.getSpecific(key: key) == true {
            stoppedOnOwnQueue.withLock { $0 = true }
            return
        }
        queue.sync {}
    }
}

/// Reports one rate before `start` and another once started, like AUHAL reading the hardware format.
final class RateChangingSource: AudioSource, @unchecked Sendable {
    let name = "Rate Mic"
    private let rate: Mutex<Double>
    private let after: Double
    let delivered = Mutex(0)
    private let running = Mutex(false)
    private let queue = DispatchQueue(label: "test.rate-mic")

    init(before: Double, after: Double) {
        rate = Mutex(before)
        self.after = after
    }

    var sampleRate: Double { rate.withLock { $0 } }

    func start(onChunk: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (AudioSourceFailure) -> Void) throws {
        rate.withLock { $0 = after }
        running.withLock { $0 = true }
        let total = Int(after)
        queue.async { [self] in
            var sent = 0
            while sent < total, running.withLock({ $0 }) {
                let chunk = (0..<480).map { Float(0.5 * sin(Double(sent + $0) * 2 * .pi * 440 / 48_000)) }
                onChunk(chunk)
                sent += chunk.count
                delivered.withLock { $0 = sent }
            }
        }
    }

    func stop() { running.withLock { $0 = false } }
}
