import Foundation
import SaylarkCore

/// Plays a fixed key timeline on the real clock, in place of the keyboard hook. Used by
/// `saylark simulate` and tests: no tap is installed.
///
/// Every step is turned into the raw key event a keyboard would send (key code and flags) and
/// decoded by `TriggerDecoder` for the current trigger, the same way the real tap decodes, so
/// `.fnDown` presses whichever key is the trigger and `.leftTwinDown` must never start a take.
public final class ScriptedFnSource: FnEventSource, @unchecked Sendable {
    public enum Step: Sendable {
        /// The trigger key (Fn, right Option or right Command) goes down / up.
        case fnDown, fnUp, escape, key
        /// The trigger goes up but the hook misses the event (tap disabled, asleep): only `isFnDown()` sees it.
        case fnUpLost
        /// The hook reports the real trigger state, as after a tap re-enable or rebuild.
        case resync
        /// A plain Return: the listen-only hook sees it, and the Return interceptor (if armed)
        /// swallows it.
        case returnKey
        /// Shift+Return: always reaches the app.
        case shiftReturn
        /// The trigger's left-hand twin (left Option / left Command; right Option when the
        /// trigger is Fn) goes down / up. Must never start a take.
        case leftTwinDown, leftTwinUp
    }

    public let kind = "script"
    /// Seconds after `start` → step.
    public let steps: [(Double, Step)]
    /// Gets the scripted Returns, like the real consuming tap. Nil: every Return reaches the app.
    public let returnTap: ScriptedReturnTap?
    private let queue = DispatchQueue(label: "saylark.scripted-fn", qos: .userInteractive)
    private let stopped = Locked(false)
    /// The "physical" trigger, which `isFnDown()` reports.
    private let physicalDown = Locked(false)
    private let trigger = Locked(TriggerKey.fn)
    /// Clock time of `start`, for reports.
    public private(set) var startedAt: Double = 0

    public init(_ steps: [(Double, Step)], returnTap: ScriptedReturnTap? = nil) {
        self.steps = steps.sorted { $0.0 < $1.0 }
        self.returnTap = returnTap
    }

    /// Hold the trigger from `at` for `hold` seconds.
    public static func hold(at: Double, for hold: Double, returnTap: ScriptedReturnTap? = nil) -> ScriptedFnSource {
        ScriptedFnSource([(at, .fnDown), (at + hold, .fnUp)], returnTap: returnTap)
    }

    /// Double-tap at `at`, then a stop tap `talk` seconds later.
    public static func handsFree(at: Double, talk: Double, returnTap: ScriptedReturnTap? = nil) -> ScriptedFnSource {
        ScriptedFnSource([(at, .fnDown), (at + 0.08, .fnUp), (at + 0.2, .fnDown), (at + 0.28, .fnUp),
                          (at + talk, .fnDown), (at + talk + 0.08, .fnUp)], returnTap: returnTap)
    }

    public func setTrigger(_ key: TriggerKey) { trigger.withLock { $0 = key } }

    public func start(_ handler: @escaping @Sendable (FnGesture.Input) -> Void) throws {
        let t0 = HotkeyClock.now
        startedAt = t0
        stopped.withLock { $0 = false }
        let steps = self.steps
        let physicalDown = self.physicalDown
        let trigger = self.trigger
        let returnTap = self.returnTap
        queue.async { [stopped] in
            var twinDown = false
            for (offset, step) in steps {
                let wait = t0 + offset - HotkeyClock.now
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if stopped.withLock({ $0 }) { return }
                let t = HotkeyClock.now
                let key = trigger.withLock { $0 }
                let held = physicalDown.withLock { $0 }
                var flags: UInt64 = held ? key.downFlags : 0
                if twinDown { flags |= Self.twin(of: key).flags }
                func flagsChanged(_ code: Int64, _ f: UInt64) {
                    handler(TriggerDecoder.input(type: .flagsChanged, keyCode: code, flags: f, time: t, trigger: key))
                }
                func keyDown(_ code: Int64, _ f: UInt64) {
                    handler(TriggerDecoder.input(type: .keyDown, keyCode: code, flags: f, time: t, trigger: key))
                }
                switch step {
                case .fnDown:
                    physicalDown.withLock { $0 = true }
                    flagsChanged(key.keyCode, flags | key.downFlags)
                case .fnUp:
                    physicalDown.withLock { $0 = false }
                    flagsChanged(key.keyCode, flags & ~key.downFlags)
                case .fnUpLost:
                    physicalDown.withLock { $0 = false }
                case .resync:
                    handler(.fnState(down: physicalDown.withLock { $0 }, time: t))
                case .escape: keyDown(KeyFacts.escapeKeyCode, flags)
                case .key: keyDown(0, flags)  // "a"
                case .returnKey, .shiftReturn:
                    let f = step == .shiftReturn ? flags | KeyFacts.shift : flags
                    keyDown(KeyFacts.returnKeyCode, f)
                    returnTap?.deliver(time: t, flags: f)
                case .leftTwinDown, .leftTwinUp:
                    twinDown = step == .leftTwinDown
                    let twin = Self.twin(of: key)
                    flagsChanged(twin.keyCode, twinDown ? flags | twin.flags : flags & ~twin.flags)
                }
            }
        }
    }

    /// The key a user might confuse with the trigger, and its flags when down.
    static func twin(of key: TriggerKey) -> (keyCode: Int64, flags: UInt64) {
        switch key {
        case .fn: (KeyFacts.rightOptionKeyCode, TriggerKey.rightOption.downFlags)
        case .rightOption: (KeyFacts.leftOptionKeyCode, KeyFacts.option | KeyFacts.deviceLeftOption)
        case .rightCommand: (KeyFacts.leftCommandKeyCode, KeyFacts.command | KeyFacts.deviceLeftCommand)
        }
    }

    public func stop() {
        stopped.withLock { $0 = true }
    }

    public func isFnDown() -> Bool? { physicalDown.withLock { $0 } }
}
