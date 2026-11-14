/// Turns raw trigger-key and Esc events into dictation gestures. Pure: the keyboard hook feeds it
/// inputs with event timestamps, and a timer feeds it `.tick` at `deadline`.
///
/// "Fn" below means the trigger key (`TriggerKey`: Fn, right Option or right Command). The hook
/// decodes the chosen key into `.fn` inputs and every other modifier (Fn itself, left Option, …)
/// into `.modifier`, so the same machine serves every trigger.
///
/// - Fn down starts a take at once (`.listen`), so no audio is lost while the gesture is decided.
/// - Released after `holdThreshold` or more: push-to-talk ends (`.finish`).
/// - Released sooner: wait `doubleTapWindow` for a second press. A second press locks the take
///   into hands-free (`.lockHandsFree`); none drops the take silently (`.discard`).
/// - In hands-free, the next Fn press stops (`.finish`).
/// - Esc during a take cancels it (`.cancel`).
/// - Fn together with any other key or modifier is a system chord (Fn+arrow, Fn+E, Fn+F5, …),
///   never a dictation: the take is discarded and everything is ignored until Fn goes up. A key
///   pressed after the hold threshold is ignored instead (the user is clearly dictating).
/// - Dictate and send (`Config.armsReturn`): once a take is clearly a dictation (a hold past the
///   threshold, or locked hands-free) the machine asks for Return to be intercepted
///   (`.armReturn`). A swallowed Return (`.returnKey`) ends the take with `.finishAndSend`. When
///   the take ends any other way, `.disarmReturn` follows its end action.
public struct FnGesture: Sendable {
    public struct Config: Sendable, Equatable {
        /// A hold at least this long (seconds) is push-to-talk.
        public var holdThreshold: Double = 0.3
        /// A second press this soon (seconds) after a short tap's release means hands-free.
        public var doubleTapWindow: Double = 0.4
        /// Hands-free stops when Fn goes up instead of down. Lets Fn chords pass during a
        /// hands-free take, at the cost of the tap's length in latency.
        public var stopOnRelease = false
        /// Emit `.armReturn` / `.disarmReturn` (dictate and send). Off by default so callers that
        /// do not intercept Return see the plain gesture actions.
        public var armsReturn = false

        public init() {}

        /// The default timings: a 0.5 s tap and a 0.5 s double-tap window (the same as Wispr Flow,
        /// so the gesture feels familiar to people switching).
        public static var wisprFlow: Config {
            var c = Config()
            c.holdThreshold = 0.5
            c.doubleTapWindow = 0.5
            return c
        }
    }

    /// One raw keyboard fact. Times are seconds on one monotonic clock (event timestamps).
    public enum Input: Sendable, Equatable {
        /// Fn went down or up. `otherModifiers`: shift, control, option or command were held.
        case fn(down: Bool, otherModifiers: Bool, time: Double)
        /// Some other key went down (Esc is `.escape`, a plain Return is `.returnPressed`).
        case key(time: Double)
        /// The listen-only hook saw a plain Return (no Shift, Control, Option or Command). It
        /// reaches the app unless the Return interceptor swallowed it, in which case `.returnKey`
        /// follows. While Return is armed it is ignored here; otherwise it is any other key.
        case returnPressed(time: Double)
        /// The Return interceptor swallowed a plain Return during the take: stop, paste, send.
        case returnKey(time: Double)
        /// Another modifier went down or up while nothing about Fn changed.
        case modifier(time: Double)
        case escape(time: Double)
        /// The timer asked for at `deadline` fired.
        case tick(time: Double)
        /// The real Fn state, read from the system (after the hook was re-enabled or rebuilt, or by
        /// the slow check while Fn is believed down). When it disagrees with what the machine last
        /// heard, an event was lost: a lost release is replayed at `time`; a lost press during a
        /// take is replayed (in hands-free it is the stop press); a lost press while idle is
        /// ignored, since its start is unknown.
        case fnState(down: Bool, time: Double)

        /// The input's timestamp.
        public var time: Double {
            switch self {
            case .fn(_, _, let t), .key(let t), .modifier(let t), .escape(let t), .tick(let t), .fnState(_, let t),
                 .returnPressed(let t), .returnKey(let t): t
            }
        }
    }

    public enum Action: Sendable, Equatable {
        case listen
        case lockHandsFree
        case finish
        case cancel
        /// The take was not a dictation (short tap, chord). Drop it without a fuss.
        case discard
        /// The take is a dictation now: start swallowing plain Return (only with `armsReturn`).
        case armReturn
        /// Stop swallowing Return. Always right after the action that ended an armed take.
        case disarmReturn
        /// Return was swallowed: end the take, paste, then press Return in the app.
        case finishAndSend
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Fn is down; not yet known whether it is a hold or the first tap of a double-tap.
        case pressed(at: Double)
        /// A short tap ended; waiting for the second press until `until`.
        case awaitingSecondTap(until: Double)
        /// The second press of a double-tap is still down.
        case lockingPress
        case handsFree
        /// Hands-free stop pending on release (only with `stopOnRelease`).
        case stopping
        /// A chord or a cancel happened while Fn was down. Ignore everything until Fn goes up.
        case ignoringUntilFnUp
    }

    public let config: Config
    public private(set) var phase: Phase = .idle
    public private(set) var fnDown = false
    /// Return is being intercepted for this take (`.armReturn` was emitted and no end yet).
    public private(set) var returnArmed = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// When the caller must send `.tick`, if anything is waiting on time.
    public var deadline: Double? {
        switch phase {
        case .awaitingSecondTap(let until): return until
        case .pressed(let at) where config.armsReturn && !returnArmed: return at + config.holdThreshold
        default: return nil
        }
    }

    /// A take is running (audio should be captured).
    public var isTakeActive: Bool {
        switch phase {
        case .idle, .ignoringUntilFnUp: false
        default: true
        }
    }

    public mutating func handle(_ input: Input) -> [Action] {
        var actions = step(input)
        // Every end of an armed take is followed by `.disarmReturn`.
        if returnArmed, let i = actions.lastIndex(where: Self.endsTake) {
            returnArmed = false
            actions.insert(.disarmReturn, at: i + 1)
        }
        return actions
    }

    private static func endsTake(_ a: Action) -> Bool {
        switch a {
        case .finish, .cancel, .discard, .finishAndSend: true
        default: false
        }
    }

    private mutating func step(_ input: Input) -> [Action] {
        switch input {
        case .fn(let down, let other, let time):
            // Repeated flag events with no change carry no information.
            guard down != fnDown else { return [] }
            fnDown = down
            return down ? fnPressed(otherModifiers: other, time: time) : fnReleased(time: time)
        case .key(let time), .modifier(let time):
            return chord(time: time)
        case .returnPressed(let time):
            // Armed: the interceptor decides (a swallowed Return arrives as `.returnKey`; one it
            // could not swallow reached the app, and the take goes on).
            return returnArmed ? [] : chord(time: time)
        case .returnKey:
            guard returnArmed, isTakeActive else { return [] }
            phase = fnDown ? .ignoringUntilFnUp : .idle
            return [.finishAndSend]
        case .escape:
            guard isTakeActive else { return [] }
            phase = fnDown ? .ignoringUntilFnUp : .idle
            return [.cancel]
        case .tick(let time):
            if case .awaitingSecondTap(let until) = phase, time >= until {
                phase = .idle
                return [.discard]
            }
            if case .pressed(let at) = phase, config.armsReturn, !returnArmed, time >= at + config.holdThreshold {
                returnArmed = true
                return [.armReturn]
            }
            return []
        case .fnState(let down, let time):
            guard down != fnDown else { return [] }
            // A lost press while idle: its start is unknown, so no take starts. The flag is left
            // alone too (arrow keys also set the Fn flag), and its release is then a no-op.
            if down, phase == .idle { return [] }
            fnDown = down
            return down ? fnPressed(otherModifiers: false, time: time) : fnReleased(time: time)
        }
    }

    /// The take ended from outside (stop button, Esc in the pill, an error). The keys still down
    /// are ignored until Fn goes up.
    public mutating func reset() {
        phase = fnDown ? .ignoringUntilFnUp : .idle
        returnArmed = false
    }

    private mutating func fnPressed(otherModifiers: Bool, time: Double) -> [Action] {
        switch phase {
        case .idle:
            if otherModifiers { phase = .ignoringUntilFnUp; return [] }
            phase = .pressed(at: time)
            return [.listen]
        case .awaitingSecondTap(let until):
            if time > until {
                // The tick came late: the first tap expired, so this press starts a new take.
                phase = otherModifiers ? .ignoringUntilFnUp : .pressed(at: time)
                return otherModifiers ? [.discard] : [.discard, .listen]
            }
            if otherModifiers { phase = .ignoringUntilFnUp; return [.discard] }
            phase = .lockingPress
            if config.armsReturn, !returnArmed {
                returnArmed = true
                return [.lockHandsFree, .armReturn]
            }
            return [.lockHandsFree]
        case .handsFree:
            if config.stopOnRelease { phase = .stopping; return [] }
            phase = .ignoringUntilFnUp
            return [.finish]
        case .pressed, .lockingPress, .stopping, .ignoringUntilFnUp:
            // Fn can't go down twice; treat as a fresh start of the ignore state.
            return []
        }
    }

    private mutating func fnReleased(time: Double) -> [Action] {
        switch phase {
        case .pressed(let at):
            // Armed means the threshold tick already called it a hold (the tick and the release
            // can land on the same instant).
            if time - at >= config.holdThreshold || returnArmed {
                phase = .idle
                return [.finish]
            }
            phase = .awaitingSecondTap(until: time + config.doubleTapWindow)
            return []
        case .lockingPress:
            phase = .handsFree
            return []
        case .stopping:
            phase = .idle
            return [.finish]
        case .ignoringUntilFnUp:
            phase = .idle
            return []
        case .idle, .awaitingSecondTap, .handsFree:
            return []
        }
    }

    /// Another key or modifier while Fn is down: a system chord, not a dictation. Once a hold has
    /// passed `holdThreshold` it is clearly a dictation, so a stray key no longer throws it away.
    private mutating func chord(time: Double) -> [Action] {
        guard fnDown else { return [] }
        switch phase {
        case .pressed(let at) where time - at >= config.holdThreshold:
            return []
        case .pressed, .lockingPress:
            phase = .ignoringUntilFnUp
            return [.discard]
        case .stopping:
            // Fn+key during hands-free: the stop tap was a chord. Keep dictating.
            phase = .handsFree
            return []
        default:
            return []
        }
    }
}

// MARK: - Decoding raw key events

/// Raw key facts: macOS virtual key codes and `CGEventFlags` bits. The device-dependent bits
/// (`NX_DEVICE…KEYMASK`) tell the left and right Option and Command keys apart.
public enum KeyFacts {
    public static let fnKeyCode: Int64 = 63
    public static let escapeKeyCode: Int64 = 53
    public static let returnKeyCode: Int64 = 36
    /// Keypad Enter; also what Fn+Return sends on a laptop keyboard.
    public static let enterKeyCode: Int64 = 76
    public static let leftOptionKeyCode: Int64 = 58
    public static let rightOptionKeyCode: Int64 = 61
    public static let leftCommandKeyCode: Int64 = 55
    public static let rightCommandKeyCode: Int64 = 54

    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let secondaryFn: UInt64 = 0x0080_0000
    public static let deviceLeftCommand: UInt64 = 0x08
    public static let deviceRightCommand: UInt64 = 0x10
    public static let deviceLeftOption: UInt64 = 0x20
    public static let deviceRightOption: UInt64 = 0x40
}

public extension TriggerKey {
    /// The key code of the trigger's own flagsChanged events.
    var keyCode: Int64 {
        switch self {
        case .fn: KeyFacts.fnKeyCode
        case .rightOption: KeyFacts.rightOptionKeyCode
        case .rightCommand: KeyFacts.rightCommandKeyCode
        }
    }

    /// Whether the trigger is down according to `flags` (an event's, or the HID state's).
    func isDown(flags: UInt64) -> Bool {
        switch self {
        case .fn: flags & KeyFacts.secondaryFn != 0
        case .rightOption: flags & KeyFacts.deviceRightOption != 0
        case .rightCommand: flags & KeyFacts.deviceRightCommand != 0
        }
    }

    /// Some other modifier is held besides the trigger itself (the left-hand twin counts).
    func otherModifiers(flags: UInt64) -> Bool {
        let others: UInt64
        switch self {
        case .fn: others = KeyFacts.shift | KeyFacts.control | KeyFacts.option | KeyFacts.command
        case .rightOption: others = KeyFacts.shift | KeyFacts.control | KeyFacts.command | KeyFacts.secondaryFn | KeyFacts.deviceLeftOption
        case .rightCommand: others = KeyFacts.shift | KeyFacts.control | KeyFacts.option | KeyFacts.secondaryFn | KeyFacts.deviceLeftCommand
        }
        return flags & others != 0
    }

    /// The flags a keyboard reports with only the trigger down (scripts and tests).
    var downFlags: UInt64 {
        switch self {
        case .fn: KeyFacts.secondaryFn
        case .rightOption: KeyFacts.option | KeyFacts.deviceRightOption
        case .rightCommand: KeyFacts.command | KeyFacts.deviceRightCommand
        }
    }

    var displayName: String {
        switch self {
        case .fn: "Fn"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        }
    }
}

/// Turns one raw key event into a gesture input for the chosen trigger. Pure, so the tap, the
/// NSEvent monitor and the scripted source all decode the same way.
public enum TriggerDecoder {
    public enum EventType: Sendable { case flagsChanged, keyDown }

    public static func input(type: EventType, keyCode: Int64, flags: UInt64, time: Double, trigger: TriggerKey) -> FnGesture.Input {
        switch type {
        case .flagsChanged:
            // Only the trigger's own key code counts: arrow keys carry the Fn flag, and the
            // left-hand Option and Command must never start a take.
            if keyCode == trigger.keyCode {
                return .fn(down: trigger.isDown(flags: flags), otherModifiers: trigger.otherModifiers(flags: flags), time: time)
            }
            return .modifier(time: time)
        case .keyDown:
            if keyCode == KeyFacts.escapeKeyCode { return .escape(time: time) }
            if isPlainReturn(keyCode: keyCode, flags: flags, trigger: trigger) { return .returnPressed(time: time) }
            return .key(time: time)
        }
    }

    /// Return (or Enter) with no Shift, Control, Option or Command, apart from the trigger's own
    /// modifier while it is held (right Option + Return during a hold is a plain Return). The
    /// Return interceptor swallows exactly these; every modified Return passes through.
    public static func isPlainReturn(keyCode: Int64, flags: UInt64, trigger: TriggerKey) -> Bool {
        guard keyCode == KeyFacts.returnKeyCode || keyCode == KeyFacts.enterKeyCode else { return false }
        var banned = KeyFacts.shift | KeyFacts.control | KeyFacts.option | KeyFacts.command
        switch trigger {
        case .fn: break
        case .rightOption:
            if flags & KeyFacts.deviceRightOption != 0, flags & KeyFacts.deviceLeftOption == 0 { banned &= ~KeyFacts.option }
        case .rightCommand:
            if flags & KeyFacts.deviceRightCommand != 0, flags & KeyFacts.deviceLeftCommand == 0 { banned &= ~KeyFacts.command }
        }
        return flags & banned == 0
    }
}
