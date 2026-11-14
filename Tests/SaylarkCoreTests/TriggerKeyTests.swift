import Testing
@testable import SaylarkCore

/// Raw key events → gesture inputs for each trigger key, and the dictate-and-send timelines.
@Suite struct TriggerKeyTests {
    typealias I = FnGesture.Input

    static func flags(_ key: TriggerKey) -> UInt64 { key.downFlags }

    /// Decodes a raw timeline of (time, type, keyCode, flags) for `trigger` and runs it through
    /// the machine, firing deadlines as the engine's timer would.
    func run(_ raw: [(Double, TriggerDecoder.EventType, Int64, UInt64)], trigger: TriggerKey, armsReturn: Bool = false,
             until end: Double = 10) -> [(Double, FnGesture.Action)] {
        var config = FnGesture.Config()
        config.armsReturn = armsReturn
        var m = FnGesture(config: config)
        var out: [(Double, FnGesture.Action)] = []
        for (t, type, code, flags) in raw {
            while let d = m.deadline, d <= t { out += m.handle(.tick(time: d)).map { (d, $0) } }
            out += m.handle(TriggerDecoder.input(type: type, keyCode: code, flags: flags, time: t, trigger: trigger)).map { (t, $0) }
        }
        while let d = m.deadline, d <= end { out += m.handle(.tick(time: d)).map { (d, $0) } }
        return out
    }

    // MARK: Decoding

    @Test(arguments: TriggerKey.allCases)
    func holdWorksForEveryTrigger(trigger: TriggerKey) {
        let r = run([(1, .flagsChanged, trigger.keyCode, trigger.downFlags), (3, .flagsChanged, trigger.keyCode, 0)], trigger: trigger)
        #expect(r.map(\.1) == [.listen, .finish])
    }

    @Test(arguments: TriggerKey.allCases)
    func doubleTapLocksHandsFreeForEveryTrigger(trigger: TriggerKey) {
        let k = trigger.keyCode, f = trigger.downFlags
        let r = run([(1, .flagsChanged, k, f), (1.1, .flagsChanged, k, 0), (1.3, .flagsChanged, k, f), (1.4, .flagsChanged, k, 0),
                     (5, .flagsChanged, k, f), (5.1, .flagsChanged, k, 0)], trigger: trigger)
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .finish])
    }

    @Test func leftOptionNeverTriggersRightOption() {
        let leftDown = KeyFacts.option | KeyFacts.deviceLeftOption
        let r = run([(1, .flagsChanged, KeyFacts.leftOptionKeyCode, leftDown), (3, .flagsChanged, KeyFacts.leftOptionKeyCode, 0)],
                    trigger: .rightOption)
        #expect(r.isEmpty)
    }

    @Test func leftCommandNeverTriggersRightCommand() {
        let leftDown = KeyFacts.command | KeyFacts.deviceLeftCommand
        let r = run([(1, .flagsChanged, KeyFacts.leftCommandKeyCode, leftDown), (3, .flagsChanged, KeyFacts.leftCommandKeyCode, 0)],
                    trigger: .rightCommand)
        #expect(r.isEmpty)
    }

    @Test func fnIsJustAModifierWhenTheTriggerIsRightOption() {
        let r = run([(1, .flagsChanged, KeyFacts.fnKeyCode, KeyFacts.secondaryFn), (3, .flagsChanged, KeyFacts.fnKeyCode, 0)],
                    trigger: .rightOption)
        #expect(r.isEmpty)
    }

    @Test func rightOptionIsJustAModifierWhenTheTriggerIsFn() {
        let r = run([(1, .flagsChanged, KeyFacts.rightOptionKeyCode, TriggerKey.rightOption.downFlags),
                     (3, .flagsChanged, KeyFacts.rightOptionKeyCode, 0)], trigger: .fn)
        #expect(r.isEmpty)
    }

    /// Left Option held, then right Option: a chord, not a dictation.
    @Test func rightOptionWithLeftOptionHeldIsAChord() {
        let left = KeyFacts.option | KeyFacts.deviceLeftOption
        let both = left | KeyFacts.deviceRightOption
        let r = run([(0.5, .flagsChanged, KeyFacts.leftOptionKeyCode, left), (1, .flagsChanged, KeyFacts.rightOptionKeyCode, both),
                     (3, .flagsChanged, KeyFacts.rightOptionKeyCode, left)], trigger: .rightOption)
        #expect(r.isEmpty)
    }

    /// Right Command + C within the hold threshold is a shortcut: discarded.
    @Test func rightCommandShortcutIsDiscarded() {
        let f = TriggerKey.rightCommand.downFlags
        let r = run([(1, .flagsChanged, KeyFacts.rightCommandKeyCode, f), (1.1, .keyDown, 8, f), (1.2, .flagsChanged, KeyFacts.rightCommandKeyCode, 0)],
                    trigger: .rightCommand)
        #expect(r.map(\.1) == [.listen, .discard])
    }

    /// Releasing right Option while left Option stays down still reads as "up" (device bits).
    @Test func rightOptionUpWhileLeftHeldIsAnUp() {
        let input = TriggerDecoder.input(type: .flagsChanged, keyCode: KeyFacts.rightOptionKeyCode,
                                         flags: KeyFacts.option | KeyFacts.deviceLeftOption, time: 1, trigger: .rightOption)
        guard case .fn(let down, let other, _) = input else { Issue.record("not a trigger event"); return }
        #expect(!down)
        #expect(other)
    }

    @Test func plainReturnRules() {
        let plain = TriggerDecoder.isPlainReturn
        #expect(plain(KeyFacts.returnKeyCode, 0, .fn))
        #expect(plain(KeyFacts.enterKeyCode, KeyFacts.secondaryFn, .fn))  // Fn+Return on a laptop
        #expect(!plain(KeyFacts.returnKeyCode, KeyFacts.shift, .fn))
        #expect(!plain(KeyFacts.returnKeyCode, KeyFacts.command, .fn))
        #expect(!plain(KeyFacts.returnKeyCode, KeyFacts.option, .fn))
        #expect(!plain(KeyFacts.returnKeyCode, KeyFacts.control, .fn))
        // The trigger's own modifier while held is fine; the left twin is not.
        #expect(plain(KeyFacts.returnKeyCode, TriggerKey.rightOption.downFlags, .rightOption))
        #expect(!plain(KeyFacts.returnKeyCode, KeyFacts.option | KeyFacts.deviceLeftOption, .rightOption))
        #expect(plain(KeyFacts.returnKeyCode, TriggerKey.rightCommand.downFlags, .rightCommand))
        #expect(!plain(KeyFacts.returnKeyCode, KeyFacts.command | KeyFacts.deviceLeftCommand, .rightCommand))
        #expect(!plain(KeyFacts.returnKeyCode, TriggerKey.rightOption.downFlags | KeyFacts.shift, .rightOption))
        #expect(!plain(0, 0, .fn))
    }

    // MARK: Dictate and send

    static func armed() -> FnGesture.Config {
        var c = FnGesture.Config()
        c.armsReturn = true
        return c
    }

    func timeline(_ inputs: [I], until end: Double = 30) -> [(Double, FnGesture.Action)] {
        var m = FnGesture(config: Self.armed())
        var out: [(Double, FnGesture.Action)] = []
        for input in inputs {
            while let d = m.deadline, d <= input.time { out += m.handle(.tick(time: d)).map { (d, $0) } }
            out += m.handle(input).map { (input.time, $0) }
        }
        while let d = m.deadline, d <= end { out += m.handle(.tick(time: d)).map { (d, $0) } }
        return out
    }

    static func down(_ t: Double) -> I { .fn(down: true, otherModifiers: false, time: t) }
    static func up(_ t: Double) -> I { .fn(down: false, otherModifiers: false, time: t) }

    @Test func holdArmsReturnAtTheThresholdAndReturnSends() {
        // Hold from 1; armed at 1.3; Return (seen listen-only, then swallowed) at 4; release at 4.2.
        let r = timeline([Self.down(1), .returnPressed(time: 4), .returnKey(time: 4.001), Self.up(4.2)])
        #expect(r.map(\.1) == [.listen, .armReturn, .finishAndSend, .disarmReturn])
        #expect(r.map(\.0) == [1, 1.3, 4.001, 4.001])
    }

    @Test func handsFreeArmsOnLockAndReturnSends() {
        let r = timeline([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4), .returnKey(time: 9)])
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .armReturn, .finishAndSend, .disarmReturn])
    }

    @Test func triggerStopWithoutReturnDisarms() {
        let r = timeline([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4), Self.down(9), Self.up(9.1)])
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .armReturn, .finish, .disarmReturn])
    }

    @Test func escapeDisarms() {
        let r = timeline([Self.down(1), .escape(time: 2), Self.up(2.2)])
        #expect(r.map(\.1) == [.listen, .armReturn, .cancel, .disarmReturn])
    }

    /// A short tap is not a dictation yet: Return is not armed, a Return then reaches the app,
    /// and the tap is discarded when its double-tap window runs out.
    @Test func shortTapNeverArms() {
        let r = timeline([Self.down(1), Self.up(1.1), .returnPressed(time: 1.2)])
        #expect(r.map(\.1) == [.listen, .discard])
    }

    /// A quick Return right after the trigger goes down is a chord (Fn+Return), not a send.
    @Test func returnBeforeTheHoldThresholdIsAChord() {
        let r = timeline([Self.down(1), .returnPressed(time: 1.1), Self.up(1.2)])
        #expect(r.map(\.1) == [.listen, .discard])
    }

    /// The interceptor could not swallow it (not installed, disabled by the system): only the
    /// listen-only Return arrives. It reached the app; the take goes on and nothing is sent.
    @Test func unswallowedReturnLeavesTheTakeRunning() {
        let r = timeline([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4), .returnPressed(time: 5), Self.down(9), Self.up(9.1)])
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .armReturn, .finish, .disarmReturn])
    }

    /// Shift+Return (a `.key`) during hands-free changes nothing.
    @Test func modifiedReturnPassesThrough() {
        let r = timeline([Self.down(1), Self.up(1.1), Self.down(1.3), Self.up(1.4), .key(time: 5), Self.down(9), Self.up(9.1)])
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .armReturn, .finish, .disarmReturn])
    }

    /// A swallowed Return after the take ended (a late event) does nothing.
    @Test func lateReturnKeyIsIgnored() {
        let r = timeline([Self.down(1), Self.up(3), .returnKey(time: 3.1)])
        #expect(r.map(\.1) == [.listen, .armReturn, .finish, .disarmReturn])
    }

    /// Return during the second press of the double-tap: armed at the lock, so it sends.
    @Test func returnDuringLockingPressSends() {
        let r = timeline([Self.down(1), Self.up(1.1), Self.down(1.3), .returnPressed(time: 1.35), .returnKey(time: 1.36), Self.up(1.4)])
        #expect(r.map(\.1) == [.listen, .lockHandsFree, .armReturn, .finishAndSend, .disarmReturn])
    }

    /// Without `armsReturn` the machine behaves exactly as before: no arming, no deadline in a hold.
    @Test func armingIsOffByDefault() {
        var m = FnGesture()
        #expect(m.handle(Self.down(1)) == [.listen])
        #expect(m.deadline == nil)
        #expect(m.handle(.returnKey(time: 2)) == [])
    }

    /// The lost-release resync works the same for every trigger: the machine only sees `.fnState`.
    @Test func lostReleaseResyncEndsAnArmedTake() {
        let r = timeline([Self.down(1), .fnState(down: false, time: 5)])
        #expect(r.map(\.1) == [.listen, .armReturn, .finish, .disarmReturn])
    }
}
