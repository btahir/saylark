import AppKit
import CoreGraphics
import Foundation
import SaylarkCore

/// Swallows a plain Return during a take, for dictate-and-send. The only part of Saylark that
/// consumes key events, and only while armed: outside a take nothing is installed and the hook
/// stays listen-only.
///
/// Fail safe: if the consuming tap can't be installed (`arm` returns false) or the system disables
/// it, Return passes through to the app untouched, and since `onReturn` is only called for a
/// Return that was actually swallowed, nothing is ever sent twice.
public protocol ReturnInterceptor: AnyObject, Sendable {
    /// Short name for logs and metrics ("tap", "script").
    var kind: String { get }
    /// Starts swallowing plain Return (`TriggerDecoder.isPlainReturn`) and calls `onReturn` (on
    /// any thread) with the event time, once per press. Returns false when interception is not
    /// possible; Return then reaches the app.
    func arm(trigger: TriggerKey, onReturn: @escaping @Sendable (Double) -> Void) -> Bool
    /// Stops swallowing. A Return still held keeps its key-up and repeats swallowed until it is
    /// released (or a short cap), so a held key can't auto-repeat into the app.
    func disarm()
}

/// The real interceptor: an active `CGEventTap` at the session level, installed on its own thread
/// for the length of an armed take and removed afterwards. The callback only reads the key code,
/// the flags and an armed flag; anything else passes through.
///
/// Active taps need Accessibility. `tapDisabledByTimeout` / `ByUserInput` are not repaired during
/// the take: a disabled tap passes Return through, which is the safe failure.
public final class ReturnKeyTap: ReturnInterceptor, @unchecked Sendable {
    public let kind = "tap"

    struct State {
        var handler: (@Sendable (Double) -> Void)?
        var trigger = TriggerKey.fn
        var armed = false
        /// A Return key-down was swallowed and its key-up has not come yet.
        var holding = false
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var disabledBySystem = 0
    }

    let state = Locked(State())
    /// After `disarm`, a held Return keeps the tap this long at most.
    public var holdCap = 2.0

    public init() {}

    /// How many times the system disabled the tap during a take (diagnostics).
    public var disabledCount: Int { state.withLock { $0.disabledBySystem } }

    public func arm(trigger: TriggerKey, onReturn: @escaping @Sendable (Double) -> Void) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let runLoop = startThread() else { return false }
        state.withLock { s in
            s.handler = onReturn
            s.trigger = trigger
            s.armed = true
        }
        let done = DispatchSemaphore(value: 0)
        let ok = Locked(false)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            ok.withLock { $0 = install() }
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        // Installing a tap takes about a millisecond; never hold the main thread long for it.
        guard done.wait(timeout: .now() + 0.2) == .success, ok.withLock({ $0 }) else {
            disarmNow()
            return false
        }
        return true
    }

    public func disarm() {
        let (holding, runLoop) = state.withLock { s -> (Bool, CFRunLoop?) in
            s.armed = false
            s.handler = nil
            return (s.holding, s.runLoop)
        }
        guard let runLoop else { return }
        if holding {
            // Keep swallowing the held Return's repeats and key-up; remove at key-up or the cap.
            DispatchQueue.global().asyncAfter(deadline: .now() + holdCap) { [weak self] in self?.removeIfIdle(force: true) }
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in uninstall() }
        CFRunLoopWakeUp(runLoop)
    }

    private func disarmNow() {
        state.withLock { s in s.armed = false; s.handler = nil; s.holding = false }
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in uninstall() }
        CFRunLoopWakeUp(runLoop)
    }

    private func removeIfIdle(force: Bool) {
        let remove = state.withLock { s -> Bool in
            guard !s.armed, force || !s.holding else { return false }
            s.holding = false
            return true
        }
        guard remove, let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in uninstall() }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Tap thread

    private func startThread() -> CFRunLoop? {
        if let r = state.withLock({ $0.runLoop }) { return r }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            state.withLock { $0.runLoop = CFRunLoopGetCurrent() }
            // A source so the run loop keeps running with no tap installed.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "saylark.return-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return state.withLock { $0.runLoop }
    }

    private func install() -> Bool {
        if state.withLock({ $0.port }) != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: returnTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        state.withLock { $0.port = port; $0.source = source }
        return true
    }

    private func uninstall() {
        let (port, source) = state.withLock { s in
            let r = (s.port, s.source)
            s.port = nil; s.source = nil
            return r
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
    }

    /// The decision, kept small: true swallows the event.
    fileprivate func swallow(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Not re-enabled: Return now passes through, and no `onReturn` can follow.
            state.withLock { s in s.armed = false; s.holding = false; s.disabledBySystem += 1 }
            return false
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == PostedEventMarker.value { return false }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == KeyFacts.returnKeyCode || code == KeyFacts.enterKeyCode else { return false }
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let time = HotkeyClock.seconds(eventTimestamp: event.timestamp)
            let (swallowed, handler, removeNow) = state.withLock { s -> (Bool, (@Sendable (Double) -> Void)?, Bool) in
                if type == .keyUp {
                    guard s.holding else { return (false, nil, false) }
                    s.holding = false
                    return (true, nil, !s.armed)
                }
                if s.holding { return (true, nil, false) }  // auto-repeat of a swallowed Return
                guard s.armed, !repeated, TriggerDecoder.isPlainReturn(keyCode: code, flags: event.flags.rawValue, trigger: s.trigger) else {
                    return (false, nil, false)
                }
                s.holding = true
                return (true, s.handler, false)
            }
            handler?(time)
            if removeNow { uninstall() }  // on the tap thread already
            return swallowed
        default:
            return false
        }
    }
}

private func returnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ReturnKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.swallow(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Scripted stand-in for tests and `saylark simulate`. `ScriptedFnSource` hands it each scripted
/// Return; it decides like the real tap and records what reached the "app".
public final class ScriptedReturnTap: ReturnInterceptor, @unchecked Sendable {
    public let kind = "script"
    private struct State {
        var handler: (@Sendable (Double) -> Void)?
        var trigger = TriggerKey.fn
        var armed = false
        var arms = 0
        var passedThrough: [Double] = []
        var swallowed: [Double] = []
        var armedAt = 0.0
    }

    private let state = Locked(State())
    /// `arm` fails (no Accessibility, tap could not be created).
    public let installFails: Bool
    /// The system disables the tap this long after it is armed (nil: never).
    public let disabledAfter: Double?

    public init(installFails: Bool = false, disabledAfter: Double? = nil) {
        self.installFails = installFails
        self.disabledAfter = disabledAfter
    }

    public var isArmed: Bool { state.withLock { $0.armed } }
    public var armCount: Int { state.withLock { $0.arms } }
    /// Times of plain Returns that reached the app (not swallowed).
    public var passedThrough: [Double] { state.withLock { $0.passedThrough } }
    public var swallowed: [Double] { state.withLock { $0.swallowed } }

    public func arm(trigger: TriggerKey, onReturn: @escaping @Sendable (Double) -> Void) -> Bool {
        guard !installFails else { return false }
        let now = HotkeyClock.now
        state.withLock { s in
            s.handler = onReturn
            s.trigger = trigger
            s.armed = true
            s.arms += 1
            s.armedAt = now
        }
        return true
    }

    public func disarm() {
        state.withLock { s in s.armed = false; s.handler = nil }
    }

    /// A Return key-down from the script. Returns true if it was swallowed.
    @discardableResult
    public func deliver(time: Double, keyCode: Int64 = KeyFacts.returnKeyCode, flags: UInt64) -> Bool {
        let disabledAfter = self.disabledAfter
        let handler = state.withLock { s -> (@Sendable (Double) -> Void)? in
            let disabled = disabledAfter.map { time - s.armedAt >= $0 } ?? false
            guard s.armed, !disabled, TriggerDecoder.isPlainReturn(keyCode: keyCode, flags: flags, trigger: s.trigger) else {
                s.passedThrough.append(time)
                return nil
            }
            s.swallowed.append(time)
            return s.handler
        }
        handler?(time)
        return handler != nil
    }
}
