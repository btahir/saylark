import AppKit
import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark simulate --active`: Active mode end to end against a pretend target app. Nothing real is
/// touched: the clipboard is an in-memory one, keys go to a recorder, focus is scripted, and the
/// Return tap is the scripted one. The pretend app reads the clipboard 15 ms after ⌘V, the way a
/// real app does, and every step is printed with its time.
@MainActor
final class ActiveSimulation {
    /// The user's clipboard before the take: text plus a rich type, so a lossy restore shows.
    static let userClipboard = PasteboardSnapshot.Item([
        .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("clipboard from before the take".utf8)),
        .init(type: "public.rtf", data: Data("{\\rtf1 before}".utf8)),
    ])

    let pasteboard: LoggingPasteboard
    let keys = RecordingKeyPoster()
    let probe: LoggingFocusProbe
    let tap = ScriptedReturnTap()
    let readDelay: Double
    private(set) var field = ""
    private(set) var sentText: [String] = []
    private(set) var steps: [(String, Double)] = []
    var t0: Double = 0

    init(noField: Bool, noClipboard: Bool, readDelay: Double = 0.015) {
        self.readDelay = readDelay
        let pb = MemoryPasteboard(items: [Self.userClipboard])
        pb.access = noClipboard ? .wouldPrompt : .allowed
        let focus = noField
            ? FocusInfo(kind: .notText, engine: .native, pid: 4242)
            : FocusInfo(kind: .editableText, engine: .web, pid: 4242, caret: .init(before: "", after: ""))
        pasteboard = LoggingPasteboard(pb)
        probe = LoggingFocusProbe(focus)
        pasteboard.note = { [unowned self] in self.note($0) }
        probe.note = { [unowned self] s in DispatchQueue.main.async { MainActor.assumeIsolated { self.note(s) } } }
        keys.onPaste = { [unowned self] _ in
            note("⌘V posted")
            DispatchQueue.main.asyncAfter(deadline: .now() + readDelay) {
                MainActor.assumeIsolated {
                    self.note("target read the clipboard")
                    self.field += self.pasteboard.memory.readString() ?? ""
                }
            }
        }
        keys.onReturn = { [unowned self] _ in
            note("Return posted")
            sentText.append(field)
        }
    }

    func note(_ s: String) {
        let now = HotkeyClock.now
        steps.append((s, now))
        print(String(format: "%8.1f ms  ", (now - t0) * 1000) + "[active] " + s)
    }

    func time(of s: String) -> Double? { steps.first { $0.0 == s }?.1 }

    /// Waits up to `seconds` for the step `s` (a paste from the menu is not a take, so
    /// `waitForTakes` does not cover its read and restore). False on timeout.
    func waitFor(_ s: String, seconds: Double = 3) async -> Bool {
        let end = HotkeyClock.now + seconds
        while time(of: s) == nil {
            if HotkeyClock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func inserter() -> Inserter {
        let pb = pasteboard, probe = self.probe
        return Inserter(parts: .init(
            pasteboard: pb, keys: keys, focus: probe, watcher: PollingFieldWatcher(probe: probe),
            accessibility: RecordingAccessibilityInserter(result: false),
            environment: { .init(clipboard: pb.access, canPostKeys: true) }))
    }

    var clipboardRestored: Bool { pasteboard.memory.items == [Self.userClipboard] }

    func summary(released: Double?) {
        print("\n--- active ---")
        print("field text: \(field.isEmpty ? "(empty)" : field)")
        if !sentText.isEmpty { print("sent (field when Return arrived): \(sentText.map { $0.isEmpty ? "(empty)" : $0 }.joined(separator: " | "))") }
        print("prior clipboard came back: \(clipboardRestored ? "yes, every type" : "NO")")
        let order = ["focus captured", "clipboard snapshot", "transient write", "⌘V posted", "target read the clipboard", "Return posted", "clipboard restored"]
        let seen = order.compactMap { name in time(of: name).map { (name, $0) } }
        print("order: " + seen.map(\.0).joined(separator: " → "))
        if let read = time(of: "target read the clipboard"), let ret = time(of: "Return posted") {
            print("Return after the read: \(ret > read ? "yes" : "NO"), +\(fmt((ret - read) * 1000, 1)) ms")
        }
        if let released, let paste = time(of: "⌘V posted") {
            print("release → ⌘V posted: \(fmt((paste - released) * 1000, 1)) ms")
        }
        print("tap: armed \(tap.armCount)x, swallowed \(tap.swallowed.count), passed through \(tap.passedThrough.count)")
    }
}

/// An in-memory clipboard that prints what the insertion path does to it.
@MainActor final class LoggingPasteboard: SaylarkEngine.Pasteboard {
    let memory: MemoryPasteboard
    var note: (String) -> Void = { _ in }

    init(_ memory: MemoryPasteboard) { self.memory = memory }

    var changeCount: Int { memory.changeCount }
    var access: InsertionMachine.ClipboardAccess { memory.access }

    func snapshot() throws -> PasteboardSnapshot {
        let s = try memory.snapshot()
        note("clipboard snapshot")
        return s
    }

    func writeTransient(_ text: String, onRead: @escaping @MainActor () -> Void) -> Int {
        note("transient write")
        return memory.writeTransient(text, onRead: onRead)
    }

    func restore(_ snapshot: PasteboardSnapshot, ifChangeCount expected: Int) -> Bool {
        let ok = memory.restore(snapshot, ifChangeCount: expected)
        note(ok ? "clipboard restored" : "clipboard not restored (changed meanwhile)")
        return ok
    }

    func writePlain(_ text: String) {
        note("plain copy")
        memory.writePlain(text)
    }

    func requestAccess() -> InsertionMachine.ClipboardAccess { memory.requestAccess() }
}

/// Scripted focus that says when it is asked.
final class LoggingFocusProbe: FocusProbe, @unchecked Sendable {
    let info: FocusInfo
    var note: @Sendable (String) -> Void = { _ in }
    private let calls = Locked(0)

    init(_ info: FocusInfo) { self.info = info }

    func focused() async -> FocusInfo {
        let n = calls.withLock { c -> Int in c += 1; return c }
        if n == 1 { note("focus captured") } else if n <= 3 { note("focus checked") }
        return info
    }
}
