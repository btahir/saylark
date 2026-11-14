import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import SaylarkCore
import Synchronization

/// Fn straight from the keyboard through IOHIDManager, below every event tap. The fallback for
/// when another app's active HID-level tap swallows Fn before our tap sees it. Needs Input
/// Monitoring. Only Apple keyboards report Fn (third-party keyboards handle it in firmware).
///
/// Usages from IOHIDFamily's AppleHIDUsageTables.h (not in the public SDK):
/// page 0xFF usage 0x03 (top-case Fn, built-in keyboards) and page 0xFF01 usage 0x03 (Apple
/// vendor keyboard Fn, Magic Keyboard).
public final class FnHIDMonitor: FnEventSource, @unchecked Sendable {
    public let kind = "hid"

    private struct State {
        var manager: IOHIDManager?
        var handler: (@Sendable (FnGesture.Input) -> Void)?
        var modifiersDown = Set<UInt32>()
        var fnDown = false
        var trigger = TriggerKey.fn
    }

    private let state = Locked(State())

    public init() {}

    public func setTrigger(_ key: TriggerKey) {
        state.withLock { s in
            guard s.trigger != key else { return }
            s.trigger = key
            s.fnDown = false
        }
    }

    public func start(_ handler: @escaping @Sendable (FnGesture.Input) -> Void) throws {
        guard CGPreflightListenEventAccess() else { throw FnHookError.noPermission }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboard: [String: Int] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
        IOHIDManagerSetDeviceMatching(manager, keyboard as CFDictionary)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, hidValueCallback, refcon)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw FnHookError.hidOpenFailed(r)
        }
        state.withLock { $0.manager = manager; $0.handler = handler }
    }

    public func stop() {
        guard let manager = state.withLock({ s -> IOHIDManager? in defer { s.manager = nil; s.handler = nil }; return s.manager }) else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    fileprivate func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        let time = HotkeyClock.seconds(machTicks: IOHIDValueGetTimeStamp(value))
        let input: FnGesture.Input? = state.withLock { s in
            // Right Option is keyboard usage 0xE6, right Command 0xE7; Fn is Apple's vendor usage.
            let isTrigger: Bool = switch s.trigger {
            case .fn: (page == 0xFF || page == 0xFF01) && usage == 0x03
            case .rightOption: page == UInt32(kHIDPage_KeyboardOrKeypad) && usage == 0xE6
            case .rightCommand: page == UInt32(kHIDPage_KeyboardOrKeypad) && usage == 0xE7
            }
            if isTrigger {
                guard pressed != s.fnDown else { return nil }
                s.fnDown = pressed
                return .fn(down: pressed, otherModifiers: !s.modifiersDown.isEmpty, time: time)
            }
            switch (page, usage) {
            case (0xFF, 0x03), (0xFF01, 0x03):
                // Fn when it is not the trigger: a modifier like any other.
                if pressed { s.modifiersDown.insert(0xFF03) } else { s.modifiersDown.remove(0xFF03) }
                return .modifier(time: time)
            case (UInt32(kHIDPage_KeyboardOrKeypad), 0xE0...0xE7):
                if pressed { s.modifiersDown.insert(usage) } else { s.modifiersDown.remove(usage) }
                return .modifier(time: time)
            case (UInt32(kHIDPage_KeyboardOrKeypad), UInt32(kHIDUsage_KeyboardEscape)):
                return pressed ? .escape(time: time) : nil
            case (UInt32(kHIDPage_KeyboardOrKeypad), 0x28), (UInt32(kHIDPage_KeyboardOrKeypad), 0x58):
                // Return / keypad Enter.
                guard pressed else { return nil }
                let modified = !s.modifiersDown.subtracting([0xE6, 0xE7, 0xFF03]).isEmpty
                return modified ? .key(time: time) : .returnPressed(time: time)
            case (UInt32(kHIDPage_KeyboardOrKeypad), 0x04...0xDF):
                return pressed ? .key(time: time) : nil
            default:
                return nil
            }
        }
        if let input { state.withLock { $0.handler }?(input) }
    }
}

private func hidValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context else { return }
    Unmanaged<FnHIDMonitor>.fromOpaque(context).takeUnretainedValue().received(value)
}

/// Lists the event taps installed on this Mac (read-only; installs nothing). Used to see whether
/// another app has an active tap at the HID level that could swallow Fn before ours.
public enum EventTapCensus {
    public struct Tap: Sendable, Codable, Equatable {
        public let process: String
        public let pid: Int32
        /// "hid", "session" or "annotated".
        public let location: String
        /// Active taps can drop events; listen-only taps can't.
        public let active: Bool
        public let enabled: Bool
        public let flagsChanged: Bool
        public let keyDown: Bool
    }

    public static func taps() -> [Tap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        return list.prefix(Int(count)).map { t in
            let pid = Int32(t.tappingProcess)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            let location = switch t.tapPoint {
            case .cghidEventTap: "hid"
            case .cgSessionEventTap: "session"
            default: "annotated"
            }
            return Tap(
                process: name, pid: pid, location: location, active: t.options == .defaultTap, enabled: t.enabled,
                flagsChanged: t.eventsOfInterest & (1 << CGEventType.flagsChanged.rawValue) != 0,
                keyDown: t.eventsOfInterest & (1 << CGEventType.keyDown.rawValue) != 0)
        }
    }

    /// Other processes' active HID-level taps that watch modifier changes: these run in the same
    /// stage as ours and, if inserted after ours at the head, could drop Fn before we see it.
    public static func hidRisks(excluding pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> [Tap] {
        taps().filter { $0.pid != pid && $0.location == "hid" && $0.active && $0.enabled && $0.flagsChanged }
    }
}
