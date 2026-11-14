import AppKit
import ApplicationServices
import SaylarkCore

/// Inserts text without the clipboard, by setting the focused element's selected text.
public protocol AccessibilityInserter: Sendable {
    /// Replaces the selection in the focused element with `text`. Returns true only when the
    /// write succeeded and, where the element reports it, the caret moved to the end of the new
    /// text. Refuses (false, nothing written) when focus is no longer on `expected`'s element or
    /// the element sits inside web content.
    func insert(_ text: String, expected: FocusInfo) async -> Bool
}

/// The real one. Off the main thread for the same deadlock reason as the probe.
///
/// Only native fields: in Chromium/Electron/WebKit content `AXSelectedText` writes report
/// success without firing DOM input events, so React/ProseMirror never see the text.
public final class AXTextInserter: AccessibilityInserter, @unchecked Sendable {
    public let scope: AXFocusProbe.Scope
    public let timeout: Double
    private let queue = DispatchQueue(label: "saylark.ax-insert", qos: .userInteractive)

    public init(scope: AXFocusProbe.Scope = .systemWide, timeout: Double = 0.25) {
        self.scope = scope
        self.timeout = timeout
    }

    public func insert(_ text: String, expected: FocusInfo) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: write(text, expected: expected)) }
        }
    }

    private func write(_ text: String, expected: FocusInfo) -> Bool {
        guard AXIsProcessTrusted(), expected.allowsAccessibilityInsert else { return false }
        let pid: Int32
        switch scope {
        case .application(let p): pid = p
        case .systemWide:
            guard let p = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
            pid = p
        }
        if let want = expected.pid, want != pid { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        if let id = expected.elementID, CFHash(element) != id { return false }
        if insideWebArea(element) { return false }
        let before = range(element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        guard let before, let after = range(element) else { return true }  // nothing to verify against
        return after.location == before.location + text.utf16.count && after.length == 0
    }

    private func insideWebArea(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<12 {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    private func range(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &r) ? r : nil
    }
}

/// Records accessibility inserts and answers with a fixed result.
public final class RecordingAccessibilityInserter: AccessibilityInserter, @unchecked Sendable {
    private let log = Locked<[String]>([])
    private let result: Bool

    public init(result: Bool = true) { self.result = result }

    public var inserted: [String] { log.withLock { $0 } }

    public func insert(_ text: String, expected: FocusInfo) async -> Bool {
        log.withLock { $0.append(text) }
        return result
    }
}
