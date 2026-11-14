import Testing
@testable import SaylarkCore

/// Simulated key timelines through the Fn gesture machine. The driver ticks the machine at its
/// deadline before each input, as the real timer would.
@Suite struct FnGestureTests {
    typealias I = FnGesture.Input

    static func down(_ t: Double, mods: Bool = false) -> I { .fn(down: true, otherModifiers: mods, time: t) }
    static func up(_ t: Double) -> I { .fn(down: false, otherModifiers: false, time: t) }

    /// Runs inputs in order, firing any deadline that falls before the next input, and finally
    /// every deadline up to `until`. Returns (time, action) pairs.
    func run(_ inputs: [I], until end: Double = 10, config: FnGesture.Config = .init()) -> [(Double, FnGesture.Action)] {
        var machine = FnGesture(config: config)
        var out: [(Double, FnGesture.Action)] = []
        func time(of input: I) -> Double { input.time }
        func fireDeadlines(before t: Double) {
            while let d = machine.deadline, d <= t {
                out += machine.handle(.tick(time: d)).map { (d, $0) }
            }
        }
        for input in inputs {
            fireDeadlines(before: time(of: input))
            out += machine.handle(input).map { (time(of: input), $0) }
        }
        fireDeadlines(before: end)
        return out
    }

    func actions(_ inputs: [I], config: FnGesture.Config = .init()) -> [FnGesture.Action] {
        run(inputs, config: config).map(\.1)
    }

    // MARK: Push-to-talk

    @Test func holdIsPushToTalk() {
        let r = run([Self.down(1), Self.up(3)])
        #expect(r.map(\.1) == [.listen, .finish])
        #expect(r.map(\.0) == [1, 3])
    }

    @Test func holdExactlyAtThresholdCounts() {
        #expect(actions([Self.down(1), Self.up(1.3)]) == [.listen, .finish])
    }

    @Test func shortTapAloneIsDiscardedAfterWindow() {
        let r = run([Self.down(1), Self.up(1.1)])
        #expect(r.map(\.1) == [.listen, .discard])
        #expect(abs(r[1].0 - 1.5) < 1e-9)  // release + 0.4 s
    }

    @Test func listenFiresOnFnDownBeforeAnythingIsKnown() {
        var m = FnGesture()
        #expect(m.handle(Self.down(5)) == [.listen])
        #expect(m.isTakeActive)
        #expect(m.deadline == nil)
    }

    // MARK: Hands-free

    @Test func doubleTapLocksHandsFreeAndNextTapStops() {
        let r = run([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4), Self.down(20), Self.up(20.1)], until: 30)
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .finish])
        #expect(r.map(\.0) == [1, 1.3, 20])
    }

    @Test func secondPressJustInsideWindowStillLocks() {
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.49), Self.up(1.6)]) == [.listen, .lockHandsFree])
    }

    @Test func secondPressAfterWindowStartsNewTake() {
        let r = run([Self.down(1), Self.up(1.1), Self.down(1.6), Self.up(3)])
        #expect(r.map(\.1) == [.listen, .discard, .listen, .finish])
        #expect(r[1].0 == 1.5)
    }

    @Test func lateTickStillDiscardsFirstTapThenListens() {
        // The timer fires late: the press after the window must not lock.
        var m = FnGesture()
        _ = m.handle(Self.down(1))
        _ = m.handle(Self.up(1.1))
        #expect(m.handle(Self.down(1.7)) == [.discard, .listen])
    }

    @Test func longSecondPressStillHandsFree() {
        // Tap, then press and hold: hands-free from the second press; its release changes nothing.
        let r = run([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(3), Self.down(10)], until: 20)
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .finish])
    }

    @Test func handsFreeStopOnRelease() {
        var config = FnGesture.Config()
        config.stopOnRelease = true
        let r = run([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4), Self.down(9), Self.up(9.1)], config: config)
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .finish])
        #expect(r.last?.0 == 9.1)
    }

    @Test func handsFreeStopOnReleaseLetsChordsThrough() {
        var config = FnGesture.Config()
        config.stopOnRelease = true
        let r = run([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4),
                     Self.down(5), .key(time: 5.05), Self.up(5.1),  // Fn+arrow mid-take
                     Self.down(9), Self.up(9.1)], config: config)
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .finish])
        #expect(r.last?.0 == 9.1)
    }

    @Test func fnReleaseAfterHandsFreeStopIsIgnored() {
        var m = FnGesture()
        for i in [Self.down(1), Self.up(1.1), Self.down(1.2), Self.up(1.3)] { _ = m.handle(i) }
        #expect(m.handle(Self.down(4)) == [.finish])
        #expect(m.handle(Self.up(6)) == [])
        #expect(m.phase == .idle)
        #expect(m.handle(Self.down(7)) == [.listen])
    }

    @Test func tripleTapDoesNotRestart() {
        // Three quick taps: lock on the second, stop on the third.
        #expect(actions([Self.down(1), Self.up(1.05), Self.down(1.15), Self.up(1.2), Self.down(1.3), Self.up(1.35)])
                == [.listen, .lockHandsFree, .finish])
    }

    // MARK: Esc

    @Test func escapeCancelsHold() {
        #expect(actions([Self.down(1), .escape(time: 2), Self.up(3)]) == [.listen, .cancel])
    }

    @Test func escapeAfterCancelWhileFnHeldIgnoresRelease() {
        var m = FnGesture()
        _ = m.handle(Self.down(1))
        _ = m.handle(.escape(time: 2))
        #expect(m.phase == .ignoringUntilFnUp)
        #expect(m.handle(Self.up(3)) == [])
        #expect(m.phase == .idle)
    }

    @Test func escapeCancelsHandsFree() {
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.2), Self.up(1.3), .escape(time: 5)])
                == [.listen, .lockHandsFree, .cancel])
    }

    @Test func escapeWhileAwaitingSecondTapCancels() {
        let r = run([Self.down(1), Self.up(1.1), .escape(time: 1.2)])
        #expect(r.map(\.1) == [.listen, .cancel])
    }

    @Test func escapeWhenIdleDoesNothing() {
        #expect(actions([.escape(time: 1)]).isEmpty)
    }

    // MARK: Chords must not trigger

    @Test func fnArrowChordDiscards() {
        // Fn+Left (Home): Fn down, arrow down quickly, Fn up.
        #expect(actions([Self.down(1), .key(time: 1.05), Self.up(1.2)]) == [.listen, .discard])
    }

    @Test func fnEChordHeldLongStillDiscarded() {
        // Fn+E (emoji picker) where Fn stays down a while after E.
        let r = run([Self.down(1), .key(time: 1.1), Self.up(2.5)])
        #expect(r.map(\.1) == [.listen, .discard])
        #expect(r[1].0 == 1.1)
    }

    @Test func fnWithModifierHeldFirstNeverListens() {
        // Cmd held, then Fn: never a dictation.
        #expect(actions([Self.down(1, mods: true), Self.up(3)]).isEmpty)
    }

    @Test func modifierAddedDuringPressDiscards() {
        // Fn then Ctrl (e.g. Fn+Ctrl+F for full screen).
        #expect(actions([Self.down(1), .modifier(time: 1.1), .key(time: 1.15), Self.up(1.3)]) == [.listen, .discard])
    }

    @Test func chordOnSecondPressDiscardsWholeTake() {
        // Tap, then Fn+Down within the window.
        let r = run([Self.down(1), Self.up(1.1), Self.down(1.3), .key(time: 1.35), Self.up(1.4)])
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .discard])
    }

    @Test func secondPressWithModifierDiscards() {
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.3, mods: true), Self.up(1.4)]) == [.listen, .discard])
    }

    @Test func strayKeyLateInHoldIsIgnored() {
        // Two seconds into a hold the user brushes a key: keep the dictation.
        #expect(actions([Self.down(1), .key(time: 3), Self.up(4)]) == [.listen, .finish])
    }

    @Test func keysWithoutFnAreIgnored() {
        #expect(actions([.key(time: 1), .modifier(time: 2), Self.down(3), Self.up(4)]) == [.listen, .finish])
    }

    @Test func typingDuringHandsFreeIsIgnored() {
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.2), Self.up(1.3), .key(time: 3), .modifier(time: 4)])
                == [.listen, .lockHandsFree])
    }

    @Test func chordThenNewDictationWorks() {
        #expect(actions([Self.down(1), .key(time: 1.05), Self.up(1.2), Self.down(2), Self.up(3)])
                == [.listen, .discard, .listen, .finish])
    }

    // MARK: Robustness

    @Test func repeatedFlagEventsAreIgnored() {
        #expect(actions([Self.down(1), Self.down(1.1), Self.down(1.2), Self.up(2), Self.up(2.1)]) == [.listen, .finish])
    }

    @Test func releaseWithoutPressIsIgnored() {
        #expect(actions([Self.up(1)]).isEmpty)
    }

    @Test func resetFromStopButtonWhileFnHeld() {
        var m = FnGesture()
        _ = m.handle(Self.down(1))
        m.reset()
        #expect(!m.isTakeActive)
        #expect(m.handle(Self.up(2)) == [])
        #expect(m.handle(Self.down(3)) == [.listen])
    }

    @Test func resetFromStopButtonInHandsFree() {
        var m = FnGesture()
        for i in [Self.down(1), Self.up(1.1), Self.down(1.2), Self.up(1.3)] { _ = m.handle(i) }
        m.reset()
        #expect(m.phase == .idle)
        #expect(m.handle(Self.down(5)) == [.listen])
    }

    @Test func customThresholds() {
        var config = FnGesture.Config()
        config.holdThreshold = 0.5
        config.doubleTapWindow = 0.25
        #expect(actions([Self.down(1), Self.up(1.4)], config: config) == [.listen, .discard])
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.3)], config: config) == [.listen, .lockHandsFree])
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.4)], config: config) == [.listen, .discard, .listen])
    }

    // MARK: Lost and repeated Fn events

    static func state(_ down: Bool, _ t: Double) -> I { .fnState(down: down, time: t) }

    /// The hook missed the release of a hold. The real state (read later) replays it as a finish.
    @Test func lostReleaseOfAHoldIsReplayedFromTheRealState() {
        let r = run([Self.down(1), Self.state(false, 4)])
        #expect(r.map(\.1) == [.listen, .finish])
        #expect(r.map(\.0) == [1, 4])
    }

    /// Before: with the release lost, the next press was ignored as a repeat and the take ran on.
    @Test func afterAReplayedReleaseTheNextPressStartsATake() {
        #expect(actions([Self.down(1), Self.state(false, 4), Self.down(5), Self.up(6)]) == [.listen, .finish, .listen, .finish])
    }

    /// Without a resync, a lost release keeps the first take running through the next press.
    @Test func withoutResyncALostReleaseSwallowsTheNextPress() {
        #expect(actions([Self.down(1), Self.down(5), Self.up(6)]) == [.listen, .finish])
    }

    @Test func lostReleaseOfAShortTapStillWaitsForTheSecondTap() {
        let r = run([Self.down(1), Self.state(false, 1.1)])
        #expect(r.map(\.1) == [.listen, .discard])
    }

    @Test func lostReleaseOfTheLockingPressStillLocksHandsFree() {
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.2), Self.state(false, 1.5), Self.down(5), Self.up(5.1)])
            == [.listen, .lockHandsFree, .finish])
    }

    @Test func matchingStateIsANoOp() {
        var m = FnGesture()
        #expect(m.handle(Self.state(false, 0)) == [])
        #expect(m.handle(Self.down(1)) == [.listen])
        #expect(m.handle(Self.state(true, 2)) == [])
        #expect(m.phase == .pressed(at: 1))
    }

    /// A press the hook missed while idle: its start is unknown, so no take starts, and its
    /// release is ignored.
    @Test func lostPressWhileIdleStartsNothing() {
        #expect(actions([Self.state(true, 1), Self.up(2), Self.down(3), Self.up(4)]) == [.listen, .finish])
    }

    /// A press the hook missed during hands-free is the stop press.
    @Test func lostStopPressInHandsFreeStops() {
        #expect(actions([Self.down(1), Self.up(1.1), Self.down(1.2), Self.up(1.3), Self.state(true, 5), Self.up(5.1)])
            == [.listen, .lockHandsFree, .finish])
    }

    @Test func repeatedEventsAreIgnored() {
        #expect(actions([Self.down(1), Self.down(1.5), Self.up(3), Self.up(3.1)]) == [.listen, .finish])
    }

    /// Every input in every phase: the machine never emits two `.listen` without an end between
    /// them, and never ends a take that did not start.
    @Test func randomTimelinesKeepTakesBalanced() {
        var rng = SplitMix(seed: 42)
        for _ in 0..<2000 {
            var m = FnGesture()
            var t = 0.0
            var open = false
            for _ in 0..<40 {
                t += Double(rng.next() % 600) / 1000
                if let d = m.deadline, d <= t {
                    for a in m.handle(.tick(time: d)) { check(a, &open) }
                }
                let input: I
                switch rng.next() % 7 {
                case 6: input = Self.state(rng.next() % 2 == 0, t)
                case 0, 1: input = Self.down(t, mods: rng.next() % 10 == 0)
                case 2, 3: input = Self.up(t)
                case 4: input = .key(time: t)
                default: input = rng.next() % 2 == 0 ? .escape(time: t) : .modifier(time: t)
                }
                for a in m.handle(input) { check(a, &open) }
                #expect(m.isTakeActive == open)
            }
        }
    }

    private func check(_ a: FnGesture.Action, _ open: inout Bool) {
        switch a {
        case .listen:
            #expect(!open); open = true
        case .lockHandsFree:
            #expect(open)
        case .finish, .cancel, .discard, .finishAndSend:
            #expect(open); open = false
        case .armReturn, .disarmReturn:
            break
        }
    }

    /// The same random timelines with Return arming on and Returns in the mix: takes stay
    /// balanced, Return is armed only inside a take, and every armed take ends disarmed.
    @Test func randomTimelinesWithReturnKeepArmingBalanced() {
        var rng = SplitMix(seed: 7)
        var config = FnGesture.Config()
        config.armsReturn = true
        for _ in 0..<2000 {
            var m = FnGesture(config: config)
            var t = 0.0
            var open = false
            var armed = false
            func apply(_ actions: [FnGesture.Action]) {
                for a in actions {
                    switch a {
                    case .armReturn: #expect(open && !armed); armed = true
                    case .disarmReturn: #expect(armed); armed = false
                    case .finish, .cancel, .discard, .finishAndSend:
                        #expect(open); open = false
                    case .listen: #expect(!open && !armed); open = true
                    case .lockHandsFree: #expect(open)
                    }
                }
            }
            for _ in 0..<40 {
                t += Double(rng.next() % 600) / 1000
                while let d = m.deadline, d <= t { apply(m.handle(.tick(time: d))) }
                let input: I
                switch rng.next() % 9 {
                case 8: input = .returnKey(time: t)
                case 7: input = .returnPressed(time: t)
                case 6: input = Self.state(rng.next() % 2 == 0, t)
                case 0, 1: input = Self.down(t, mods: rng.next() % 10 == 0)
                case 2, 3: input = Self.up(t)
                case 4: input = .key(time: t)
                default: input = rng.next() % 2 == 0 ? .escape(time: t) : .modifier(time: t)
                }
                apply(m.handle(input))
                #expect(m.isTakeActive == open)
                #expect(m.returnArmed == armed)
                if armed { #expect(open) }
            }
        }
    }
}

/// Small deterministic generator for the random timeline test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
