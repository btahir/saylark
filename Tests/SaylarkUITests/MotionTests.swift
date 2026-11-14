import Foundation
import Testing
@testable import SaylarkUI
import SaylarkCore

@Suite struct SpringTests {
    private func run(_ s: inout Spring, seconds: Double, hz: Double) {
        for _ in 0..<Int(seconds * hz) { s.step(1 / hz) }
    }

    @Test func settlesOnTarget() {
        var s = Spring(0, params: PillSprings.morph)
        s.target = 100
        run(&s, seconds: 2, hz: 120)
        #expect(abs(s.value - 100) < 0.01)
        #expect(s.isSettled)
    }

    @Test func sameMotionAtAnyFrameRate() {
        for p in [PillSprings.appear, PillSprings.exit, PillSprings.shake, PillSprings.card] {
            var a = Spring(0.6, params: p), b = Spring(0.6, params: p)
            a.target = 1; b.target = 1
            run(&a, seconds: 0.1, hz: 60)
            run(&b, seconds: 0.1, hz: 120)
            #expect(abs(a.value - b.value) < 1e-9)
        }
    }

    @Test func retargetKeepsPositionAndVelocity() {
        var s = Spring(0, params: PillSprings.morph)
        s.target = 1
        run(&s, seconds: 0.05, hz: 120)
        let (v, vel) = (s.value, s.velocity)
        s.target = 0
        #expect(s.value == v && s.velocity == vel, "no jump when interrupted")
        s.step(1 / 120)
        #expect(abs(s.value - v) < abs(vel) / 120 + 0.01, "moves on smoothly from where it was")
    }

    @Test func appearIsWithin150ms() {
        var s = Spring(0.6, params: PillSprings.appear)
        s.target = 1
        var t = 0.0
        while abs(s.value - 1) > 0.02 && t < 1 { s.step(1 / 120); t += 1 / 120 }
        #expect(t <= 0.15, "scale within 0.02 of 1 after \(t) s")
    }

    @Test func exitIsGoneIn120ms() {
        var s = Spring(1, params: PillSprings.exit)
        s.target = 0
        run(&s, seconds: 0.12, hz: 120)
        #expect(s.value < 0.03)
    }
}

@Suite struct EnvelopeTests {
    @Test func rmsAndPeakOfASine() {
        let rate = 16000.0
        let samples = (0..<16000).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        let e = VoiceEnvelope.compute(id: "sine", samples: samples, sampleRate: rate)
        #expect(e.rms.count == 120)
        #expect(abs(e.rms[60] - 0.3536) < 0.01)
        #expect(abs(e.peak[60] - 0.5) < 0.01)
    }

    @Test func meterMapsSpeechAndSilence() {
        var m = LevelMeter()
        #expect(m.normalized(0) == 0)
        #expect(m.normalized(1) == 1)
        let speech = Float(pow(10, -35.0 / 20))
        var level = 0.0
        for _ in 0..<12 { level = m.update(rms: speech, dt: 1 / 120) }
        #expect(level > 0.5, "attack reaches speech level within 100 ms")
        for _ in 0..<36 { level = m.update(rms: 0, dt: 1 / 120) }
        #expect(level < 0.05, "release falls within 300 ms")
    }

    @Test func interpolatesBetweenFrames() {
        let e = VoiceEnvelope(id: "x", rate: 120, rms: [0, 1], peak: [0, 1])
        #expect(abs(e.rms(at: 0.5 / 120) - 0.5) < 1e-6)
        #expect(e.rms(at: -1) == 0)
    }
}

/// The layer tree itself: first-frame visibility, idling, hit areas and frame cost.
@MainActor @Suite struct PillViewTests {
    private func drive(_ view: PillView, _ events: [TimedPillEvent], seconds: Double, rms: Float = 0.02) -> [Double] {
        var d = PillDriver(events: events)
        var costs: [Double] = []
        for i in 0..<Int(seconds * 120) {
            let t = Double(i) / 120
            let start = DispatchTime.now().uptimeNanoseconds
            CATransactionScope.run {
                d.advance(to: t)
                view.update(state: d.state, time: t, rms: d.state.phase == .listening ? rms : nil, dt: 1 / 120)
            }
            costs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return costs
    }

    @Test func visibleOnTheFirstFrame() {
        let v = PillView()
        _ = drive(v, [TimedPillEvent(0, .listen)], seconds: 1.0 / 120)
        #expect(v.layer.sublayers!.first!.opacity >= 0.45)
    }

    @Test func idlesAfterDone() {
        let v = PillView()
        _ = drive(v, [TimedPillEvent(0, .listen), TimedPillEvent(1, .finish(.inserted))], seconds: 1.6)
        #expect(v.isIdle)
    }

    @Test func stopButtonIsClickableInHandsFree() {
        let v = PillView()
        _ = drive(v, [TimedPillEvent(0, .listen), TimedPillEvent(0.2, .lockHandsFree)], seconds: 1.2)
        let f = v.pillFrame
        #expect(v.hit(CGPoint(x: f.maxX - 16, y: f.midY)) == .stop)
        #expect(v.hit(CGPoint(x: f.minX + 20, y: f.midY)) == nil)
    }

    @Test func frameCostUnderOneMillisecond() {
        let v = PillView(theme: PillTheme(liveWords: true))
        var events = [TimedPillEvent(0, .listen), TimedPillEvent(0.3, .lockHandsFree)]
        let words = "the quick brown fox jumps over the lazy dog again and again".split(separator: " ").map(String.init)
        for i in 1...words.count { events.append(TimedPillEvent(0.3 * Double(i), .words(Array(words.prefix(i))))) }
        events.append(TimedPillEvent(4.5, .finish(.noTextField("Some text"))))
        let costs = drive(v, events, seconds: 6).dropFirst(2).sorted()
        let p99 = costs[Int(Double(costs.count) * 0.99)]
        #expect(p99 < 1.0, "p99 frame cost \(p99) ms")
    }
}

import QuartzCore

enum CATransactionScope {
    static func run(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
