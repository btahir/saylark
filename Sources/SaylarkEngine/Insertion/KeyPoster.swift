import AppKit
import Carbon.HIToolbox
import CoreGraphics

public enum KeyPostError: Error, Equatable, CustomStringConvertible {
    case cannotCreateEvent
    /// The app that should get the paste is no longer frontmost: posting would paste elsewhere.
    case targetNotFrontmost(expected: Int32, actual: Int32?)

    public var description: String {
        switch self {
        case .cannotCreateEvent: "could not create the key events"
        case .targetNotFrontmost(let e, let a): "target pid \(e) is not frontmost (frontmost: \(a.map(String.init) ?? "none"))"
        }
    }
}

/// Sends ⌘V, and Return for dictate-and-send.
@MainActor
public protocol KeyPoster: AnyObject {
    /// Posts ⌘V for the app with `targetPID` (nil when unknown).
    func postPaste(targetPID: Int32?) async throws
    /// Posts a plain Return (no modifiers) for the app with `targetPID`, after a paste it read.
    func postReturn(targetPID: Int32?) async throws
}

/// Marks key events Saylark posts (`eventSourceUserData`), so its own Return interceptor never
/// swallows them.
public enum PostedEventMarker {
    public static let value: Int64 = 0x5341_594C  // "SAYL"
}

/// ⌘V from a private event source, so keys the user still holds (Fn after a push-to-talk
/// release, Shift, Option) never merge into it. The flags on every event are set explicitly.
@MainActor
public final class SystemKeyPoster: KeyPoster {
    public enum Delivery: Sendable, Equatable {
        /// Into the HID event stream, like a real keyboard. Production. The frontmost app gets it,
        /// so the poster first checks the target is still frontmost.
        case hidTap
        /// Straight to one process, always this one, whatever `targetPID` says. The harness uses
        /// its own pid so nothing ever reaches another app.
        case onlyProcess(Int32)
    }

    public let delivery: Delivery
    /// Gap between the four events. Some Electron builds miss a zero-gap chord (VoiceInk uses
    /// 10 ms, Handy holds 100 ms); 5 ms is the starting point, to be measured per app.
    public var gap: Double
    /// The key code that produced "v" on the last post, and how it was found.
    public private(set) var lastKey: KeyboardLayout.KeyLookup?

    public init(delivery: Delivery = .hidTap, gap: Double = 0.005) {
        self.delivery = delivery
        self.gap = gap
    }

    public func postPaste(targetPID: Int32?) async throws {
        if case .hidTap = delivery, let targetPID {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == targetPID else { throw KeyPostError.targetNotFrontmost(expected: targetPID, actual: front) }
        }
        let key = KeyboardLayout.keyCode(for: "v")
        lastKey = key
        guard let source = CGEventSource(stateID: .privateState),
              let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        else { throw KeyPostError.cannotCreateEvent }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        for event in [cmdDown, vDown, vUp, cmdUp] { event.setIntegerValueField(.eventSourceUserData, value: PostedEventMarker.value) }
        for (i, event) in [cmdDown, vDown, vUp, cmdUp].enumerated() {
            if i > 0, gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
            switch delivery {
            case .hidTap: event.post(tap: .cghidEventTap)
            case .onlyProcess(let pid): event.postToPid(pid)
            }
        }
    }

    public func postReturn(targetPID: Int32?) async throws {
        if case .hidTap = delivery, let targetPID {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == targetPID else { throw KeyPostError.targetNotFrontmost(expected: targetPID, actual: front) }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        else { throw KeyPostError.cannotCreateEvent }
        for (i, event) in [down, up].enumerated() {
            // Explicit empty flags: a trigger key still held (right Option) must not turn this
            // into Option+Return.
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: PostedEventMarker.value)
            if i > 0, gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
            switch delivery {
            case .hidTap: event.post(tap: .cghidEventTap)
            case .onlyProcess(let pid): event.postToPid(pid)
            }
        }
    }
}

/// Finds the key that types a character in the current keyboard layout, so ⌘V works on Dvorak,
/// AZERTY, Colemak and the "… – QWERTY ⌘" layouts.
public enum KeyboardLayout {
    public struct KeyLookup: Sendable, Equatable {
        public var code: CGKeyCode
        /// "command" (the layout's ⌘ table), "plain", or "fallback" (ANSI position).
        public var how: String
        public var layoutID: String?
    }

    /// The physical key for `character`, first as typed with ⌘ held (layouts that switch to
    /// QWERTY under ⌘ say so in that table), then without, then the ANSI key. Main thread: the
    /// Text Input Sources API asserts it on recent macOS.
    @MainActor
    public static func keyCode(for character: Character) -> KeyLookup {
        let ansi: [Character: Int] = ["v": kVK_ANSI_V, "c": kVK_ANSI_C, "x": kVK_ANSI_X, "a": kVK_ANSI_A]
        let fallback = KeyLookup(code: CGKeyCode(ansi[character] ?? kVK_ANSI_V), how: "fallback", layoutID: nil)
        var source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        if source.flatMap(layoutData) == nil {
            // Input methods (Japanese, Chinese) have no layout data of their own.
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let source else { return fallback }
        return lookup(character, in: source) ?? fallback
    }

    /// The key for `character` in an installed layout that need not be selected (for checks:
    /// nothing about the user's input source changes). Nil if the layout isn't installed.
    @MainActor
    public static func keyCode(for character: Character, layoutID: String) -> KeyLookup? {
        let filter = [kTISPropertyInputSourceID as String: layoutID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return lookup(character, in: source)
    }

    @MainActor
    private static func lookup(_ character: Character, in source: TISInputSource) -> KeyLookup? {
        guard let data = layoutData(source) else { return nil }
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        let target = String(character).lowercased()
        for (modifiers, how) in [(UInt32((cmdKey >> 8) & 0xFF), "command"), (UInt32(0), "plain")] {
            for code in 0..<128 {
                if translate(data, code: UInt16(code), modifiers: modifiers)?.lowercased() == target {
                    return KeyLookup(code: CGKeyCode(code), how: how, layoutID: id)
                }
            }
        }
        return nil
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    private static func translate(_ layout: Data, code: UInt16, modifiers: UInt32) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Records pastes and Returns instead of sending keys. `onPaste` stands in for the target app (for
/// example, reading a `MemoryPasteboard`, which fires the read receipt).
@MainActor
public final class RecordingKeyPoster: KeyPoster {
    public enum Key: Sendable, Equatable {
        case paste(Int32?)
        case returnKey(Int32?)
    }

    public private(set) var posts: [Int32?] = []
    public private(set) var returns: [Int32?] = []
    /// Pastes and Returns in the order they were posted.
    public private(set) var log: [Key] = []
    public var onPaste: (@MainActor (Int32?) -> Void)?
    public var onReturn: (@MainActor (Int32?) -> Void)?
    public var failure: (any Error)?

    public init(onPaste: (@MainActor (Int32?) -> Void)? = nil) {
        self.onPaste = onPaste
    }

    public func postPaste(targetPID: Int32?) async throws {
        if let failure { throw failure }
        posts.append(targetPID)
        log.append(.paste(targetPID))
        onPaste?(targetPID)
    }

    public func postReturn(targetPID: Int32?) async throws {
        if let failure { throw failure }
        returns.append(targetPID)
        log.append(.returnKey(targetPID))
        onReturn?(targetPID)
    }
}
