import AppKit
import CoreGraphics
import Foundation
import SaylarkCore
import Synchronization

/// Where trigger-key and Esc facts come from. Implementations never consume or change events, so
/// Wispr Flow (or anything else) still receives every press. "Fn" in the names means the trigger
/// key (`TriggerKey`), Fn by default.
public protocol FnEventSource: AnyObject, Sendable {
    /// Short name for logs ("tap", "monitor", "hid", "script").
    var kind: String { get }
    /// Starts delivering inputs. `handler` may run on any thread; it must return quickly.
    func start(_ handler: @escaping @Sendable (FnGesture.Input) -> Void) throws
    func stop()
    /// Whether Fn is physically down right now, read from the system (not from events), or nil
    /// when the source can't tell. Cheap; the engine calls it on a slow timer while Fn is believed
    /// down, to catch a release the hook missed.
    func isFnDown() -> Bool?
    /// Which key is the trigger from now on. Takes effect for the next event.
    func setTrigger(_ key: TriggerKey)
}

public extension FnEventSource {
    func isFnDown() -> Bool? { nil }
    func setTrigger(_ key: TriggerKey) {}
}

/// The real Fn state from the window server's HID state, as the modifier flags of the next event
/// would carry it. Reads state only; posts and changes nothing.
public enum FnKeyState {
    public static func isDown() -> Bool { isDown(.fn) }

    /// The trigger's state. For right Option and right Command this reads the device-dependent
    /// bits of the HID flags state (left and right keys are told apart there).
    public static func isDown(_ key: TriggerKey) -> Bool {
        key.isDown(flags: CGEventSource.flagsState(.hidSystemState).rawValue)
    }
}

public enum FnHookError: Error, CustomStringConvertible {
    /// Neither Input Monitoring nor Accessibility is granted.
    case noPermission
    case tapCreateFailed
    case hidOpenFailed(Int32)

    public var description: String {
        switch self {
        case .noPermission: "Saylark needs Input Monitoring (or Accessibility) to hear the Fn key."
        case .tapCreateFailed: "The keyboard event tap could not be created."
        case .hidOpenFailed(let r): "The keyboard could not be opened for listening (IOReturn \(r))."
        }
    }
}

/// Seconds on the clock every key and audio timestamp uses: mach absolute time (stops in sleep).
public enum HotkeyClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public static func seconds(machTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    public static var now: Double { seconds(machTicks: mach_absolute_time()) }

    /// A CGEvent timestamp in clock seconds. CGEvent stamps are mach ticks on current systems; if a
    /// stamp is implausible (more than 2 s off), the arrival time is used instead.
    public static func seconds(eventTimestamp stamp: CGEventTimestamp) -> Double {
        let now = Self.now
        let t = seconds(machTicks: stamp)
        return abs(now - t) < 2 ? t : now
    }
}

/// Decodes raw key events into gesture inputs (`TriggerDecoder`). Shared by the tap and the
/// NSEvent monitor.
enum KeyDecoder {
    static func input(type: CGEventType, keyCode: Int64, flags: CGEventFlags, time: Double, trigger: TriggerKey = .fn) -> FnGesture.Input? {
        switch type {
        case .flagsChanged:
            return TriggerDecoder.input(type: .flagsChanged, keyCode: keyCode, flags: flags.rawValue, time: time, trigger: trigger)
        case .keyDown:
            return TriggerDecoder.input(type: .keyDown, keyCode: keyCode, flags: flags.rawValue, time: time, trigger: trigger)
        default:
            return nil
        }
    }
}

/// Listen-only `CGEventTap` at the HID level, inserted at the head, on its own high-priority
/// thread so main-thread stalls can't make macOS disable it.
///
/// Needs Input Monitoring (TCC ListenEvent). The tap re-enables itself when macOS disables it
/// (`tapDisabledByTimeout` / `ByUserInput`), checks itself every few seconds (Hex saw taps die
/// after sleep with no event), and is rebuilt on wake and on session switch.
public final class FnEventTap: FnEventSource, @unchecked Sendable {
    public let kind = "tap"

    private struct State {
        var handler: (@Sendable (FnGesture.Input) -> Void)?
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var thread: Thread?
        var observers: [any NSObjectProtocol] = []
        var reenables = 0
        var rebuilds = 0
        var trigger = TriggerKey.fn
    }

    private let state = Locked(State())

    public init() {}

    /// How many times the tap was re-enabled or rebuilt (for diagnostics).
    public var repairs: (reenables: Int, rebuilds: Int) { state.withLock { ($0.reenables, $0.rebuilds) } }

    public func start(_ handler: @escaping @Sendable (FnGesture.Input) -> Void) throws {
        guard CGPreflightListenEventAccess() else { throw FnHookError.noPermission }
        let ready = DispatchSemaphore(value: 0)
        let failed = Locked(false)
        state.withLock { $0.handler = handler }
        let thread = Thread { [self] in
            state.withLock { $0.runLoop = CFRunLoopGetCurrent() }
            if !install() { failed.withLock { $0 = true } }
            addWatchdog()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "saylark.fn-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if failed.withLock({ $0 }) {
            stop()
            throw FnHookError.tapCreateFailed
        }
        state.withLock { $0.thread = thread }
        observeWake()
    }

    public func stop() {
        let (runLoop, observers) = state.withLock { s -> (CFRunLoop?, [any NSObjectProtocol]) in
            let r = (s.runLoop, s.observers)
            s.observers = []
            s.handler = nil
            return r
        }
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            uninstall()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        state.withLock { $0.runLoop = nil; $0.thread = nil }
    }

    public func isFnDown() -> Bool? { FnKeyState.isDown(state.withLock { $0.trigger }) }

    public func setTrigger(_ key: TriggerKey) { state.withLock { $0.trigger = key } }

    /// Tears the tap down and creates it again, on the tap thread.
    public func rebuild() {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            uninstall()
            _ = install()
            state.withLock { $0.rebuilds += 1 }
            resync()
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// After the tap was off (disabled by timeout, rebuilt, asleep) events may have been missed:
    /// send the real Fn state so the gesture machine can replay a lost release.
    private func resync() {
        let input = FnGesture.Input.fnState(down: FnKeyState.isDown(state.withLock { $0.trigger }), time: HotkeyClock.now)
        state.withLock { $0.handler }?(input)
    }

    // MARK: - Tap thread

    private func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: fnTapCallback, userInfo: refcon
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

    private func addWatchdog() {
        // Every 5 s with 1 s leeway: cheap, and wakes the CPU about as often as nothing does.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0) { [weak self] _ in
            self?.checkEnabled()
        }
        CFRunLoopTimerSetTolerance(timer, 1)
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    fileprivate func checkEnabled() {
        guard let port = state.withLock({ $0.port }) else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
            state.withLock { $0.reenables += 1 }
            if !CGEvent.tapIsEnabled(tap: port) {
                uninstall()
                _ = install()
                state.withLock { $0.rebuilds += 1 }
            }
            resync()
        }
    }

    fileprivate func received(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = state.withLock({ $0.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            state.withLock { $0.reenables += 1 }
            resync()
        default:
            let time = HotkeyClock.seconds(eventTimestamp: event.timestamp)
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let (handler, trigger) = state.withLock { ($0.handler, $0.trigger) }
            guard let input = KeyDecoder.input(type: type, keyCode: code, flags: event.flags, time: time, trigger: trigger) else { return }
            handler?(input)
        }
    }

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        let observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.rebuild() }
        }
        state.withLock { $0.observers = observers }
    }
}

/// The C callback for `FnEventTap`. Copies what it needs and returns at once.
private func fnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<FnEventTap>.fromOpaque(refcon).takeUnretainedValue().received(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// Fallback when only Accessibility is granted: an `NSEvent` global monitor. It sees events after
/// the session-level taps, so another app's active tap could hide Fn from it; prefer the tap.
public final class FnGlobalMonitor: FnEventSource, @unchecked Sendable {
    public let kind = "monitor"
    private struct Token: @unchecked Sendable { let value: Any }
    private let monitor = Mutex<Token?>(nil)
    private let trigger = Locked(TriggerKey.fn)

    public init() {}

    public func start(_ handler: @escaping @Sendable (FnGesture.Input) -> Void) throws {
        guard AXIsProcessTrusted() else { throw FnHookError.noPermission }
        let trigger = self.trigger
        let install = { () -> Token? in
            NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
                guard let cg = e.cgEvent else { return }
                let type: CGEventType = e.type == .flagsChanged ? .flagsChanged : .keyDown
                // NSEvent timestamps are seconds since boot on the same mach clock.
                if let input = KeyDecoder.input(type: type, keyCode: Int64(e.keyCode), flags: cg.flags, time: e.timestamp, trigger: trigger.withLock { $0 }) {
                    handler(input)
                }
            }.map(Token.init)
        }
        let token = Thread.isMainThread ? install() : DispatchQueue.main.sync { install() }
        monitor.withLock { $0 = token }
    }

    public func isFnDown() -> Bool? { FnKeyState.isDown(trigger.withLock { $0 }) }

    public func setTrigger(_ key: TriggerKey) { trigger.withLock { $0 = key } }

    public func stop() {
        guard let token = monitor.withLock({ m -> Token? in defer { m = nil }; return m }) else { return }
        DispatchQueue.main.async { NSEvent.removeMonitor(token.value) }
    }
}

/// Picks the best available source: the listen-only tap (Input Monitoring), else the NSEvent
/// monitor (Accessibility), else the HID fallback when asked for. Never prompts.
public enum FnHook {
    public enum Preference: String, Sendable {
        case automatic, tap, monitor, hid
    }

    public static func makeSource(_ preference: Preference = .automatic) throws -> any FnEventSource {
        switch preference {
        case .tap: return FnEventTap()
        case .monitor: return FnGlobalMonitor()
        case .hid: return FnHIDMonitor()
        case .automatic:
            if CGPreflightListenEventAccess() { return FnEventTap() }
            if AXIsProcessTrusted() { return FnGlobalMonitor() }
            throw FnHookError.noPermission
        }
    }
}
