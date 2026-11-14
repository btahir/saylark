import AppKit
import ApplicationServices
import SaylarkCore

/// Reads what has keyboard focus. Never blocks for long: a hung app yields `.unknown`.
public protocol FocusProbe: Sendable {
    func focused() async -> FocusInfo
}

/// The accessibility probe. Runs off the main thread (an AX query to our own process from the
/// main thread would deadlock, and a slow app must never stall the pill), with a hard overall
/// deadline: whatever is not known by then is `.unknown`.
///
/// Electron and Chromium build their accessibility tree only when asked. The first time the probe
/// sees such an app it sets `AXManualAccessibility` on it (documented by Electron; Chromium
/// honours it too). Caveats: the tree build makes that first query slow (it usually times out and
/// the paste goes ahead as `.unknown`), and the app spends some CPU and memory keeping the tree
/// alive until it quits. Call `prepare(pid:)` when an app activates so the tree is ready by the
/// time the user dictates. `AXEnhancedUserInterface` is off by default: it changes app behaviour
/// (window managers such as Rectangle turn it off to stop animations breaking).
public final class AXFocusProbe: FocusProbe, @unchecked Sendable {
    public enum Scope: Sendable, Equatable {
        /// Whatever app is frontmost. Production.
        case systemWide
        /// One app's focused element, whether or not it is frontmost (the harness, on itself).
        case application(Int32)
    }

    public let scope: Scope
    /// Hard deadline for one probe, seconds.
    public let timeout: Double
    public var useEnhancedUserInterface = false
    private let queue = DispatchQueue(label: "saylark.focus-probe", qos: .userInteractive, attributes: .concurrent)
    private let prepared = Locked<Set<Int32>>([])
    private let engines = Locked<[Int32: FocusInfo.Engine]>([:])

    public init(scope: Scope = .systemWide, timeout: Double = 0.1) {
        self.scope = scope
        self.timeout = timeout
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public func focused() async -> FocusInfo {
        let started = DispatchTime.now()
        let timeout = self.timeout
        return await withCheckedContinuation { (cont: CheckedContinuation<FocusInfo, Never>) in
            let done = Locked(false)
            let finish: @Sendable (FocusInfo) -> Void = { info in
                let first = done.withLock { was -> Bool in
                    defer { was = true }
                    return !was
                }
                if first { cont.resume(returning: FocusClassifier.refine(info)) }
            }
            queue.async { [self] in
                var info = read()
                info.probeMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                finish(info)
            }
            queue.asyncAfter(deadline: started + timeout) { [self] in
                var info = FocusInfo.unknown(note: "timed out after \(Int(timeout * 1000)) ms")
                if case .application(let pid) = scope { info.pid = pid } else { info.pid = Self.frontmostPID() }
                info.bundleID = info.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                info.probeMs = timeout * 1000
                finish(info)
            }
        }
    }

    /// Turns on Electron/Chromium accessibility for `pid` ahead of time.
    public func prepare(pid: Int32) {
        queue.async { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            enableWebAccessibility(app, pid: pid)
        }
    }

    // MARK: - Reading (on `queue`)

    private func read() -> FocusInfo {
        let pid: Int32
        switch scope {
        case .application(let p): pid = p
        case .systemWide:
            guard let p = Self.frontmostPID() else { return .unknown(note: "no frontmost app") }
            pid = p
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard AXIsProcessTrusted() else { return .unknown(pid: pid, bundleID: bundleID, note: "accessibility off") }
        let engine = engine(for: pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        if engine == .web { enableWebAccessibility(app, pid: pid) }

        var element: AXUIElement? = copy(app, kAXFocusedUIElementAttribute)
        if element == nil, scope == .systemWide {
            // The app element sometimes has no answer when the system-wide one does (VoiceInk).
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, Float(timeout))
            if let el: AXUIElement = copy(system, kAXFocusedUIElementAttribute) {
                var elPID: pid_t = 0
                if AXUIElementGetPid(el, &elPID) == .success, elPID == pid { element = el }
            }
        }
        guard let element else {
            var info = FocusInfo(kind: FocusClassifier.kind(hasFocusedElement: false, role: nil, subrole: nil, editable: nil,
                                                            valueSettable: false, selectedTextSettable: false, engine: engine),
                                 engine: engine, pid: pid, bundleID: bundleID)
            info.note = "no focused element"
            return info
        }
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        let role: String? = copy(element, kAXRoleAttribute)
        let subrole: String? = copy(element, kAXSubroleAttribute)
        let editable: Bool? = copy(element, "AXEditable")
        let valueSettable = settable(element, kAXValueAttribute)
        let selectedSettable = settable(element, kAXSelectedTextAttribute)
        let kind = FocusClassifier.kind(hasFocusedElement: true, role: role, subrole: subrole, editable: editable,
                                        valueSettable: valueSettable, selectedTextSettable: selectedSettable, engine: engine)
        var info = FocusInfo(kind: kind, engine: engine, pid: pid, bundleID: bundleID, role: role, subrole: subrole,
                             elementID: CFHash(element), canSetSelectedText: selectedSettable)
        // Caret context, never for password fields. Only three characters, kept in memory.
        if kind != .secureText, let range = selectedRange(element) {
            info.selectionLocation = range.location
            info.selectionLength = range.length
            info.caret = caret(element, range: range)
        }
        return info
    }

    private func caret(_ element: AXUIElement, range: CFRange) -> FocusInfo.Caret {
        var caret = FocusInfo.Caret()
        let start = range.location
        caret.before = start == 0 ? "" : string(element, CFRange(location: max(0, start - 2), length: min(2, start)))
        let end = range.location + range.length
        if let total: Int = copy(element, kAXNumberOfCharactersAttribute) {
            caret.after = end >= total ? "" : string(element, CFRange(location: end, length: 1))
        }
        return caret
    }

    private func enableWebAccessibility(_ app: AXUIElement, pid: Int32) {
        let first = prepared.withLock { $0.insert(pid).inserted }
        guard first else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if useEnhancedUserInterface {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private func engine(for pid: Int32) -> FocusInfo.Engine {
        if let known = engines.withLock({ $0[pid] }) { return known }
        let app = NSRunningApplication(processIdentifier: pid)
        let engine = Self.engine(bundleID: app?.bundleIdentifier, bundleURL: app?.bundleURL)
        engines.withLock { $0[pid] = engine }
        return engine
    }

    /// Browsers and anything built on Electron or a Chromium framework are `.web`.
    static let webBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    static func engine(bundleID: String?, bundleURL: URL?) -> FocusInfo.Engine {
        if let bundleID, webBundleIDs.contains(bundleID) { return .web }
        guard let bundleURL else { return .unknown }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        if names.contains(where: { $0 == "Electron Framework.framework" || $0.contains("Chromium") || $0.hasSuffix("Chrome Framework.framework") }) {
            return .web
        }
        return .native
    }

    static func frontmostPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    // MARK: - AX helpers

    private func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == Bool.self { return (value as? NSNumber)?.boolValue as? T }
        if T.self == Int.self { return (value as? NSNumber)?.intValue as? T }
        return value as? T
    }

    private func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    private func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &value) == .success
        else { return nil }
        return value as? String
    }
}

/// Plays a fixed list of focus answers, in place of accessibility. The last one repeats.
public final class ScriptedFocusProbe: FocusProbe, @unchecked Sendable {
    private let answers: Locked<[FocusInfo]>
    private let calls = Locked(0)

    public init(_ answers: [FocusInfo]) {
        precondition(!answers.isEmpty)
        self.answers = Locked(answers)
    }

    public var callCount: Int { calls.withLock { $0 } }

    /// Replaces what the probe will answer from now on.
    public func set(_ answers: [FocusInfo]) {
        self.answers.withLock { $0 = answers }
    }

    public func focused() async -> FocusInfo {
        calls.withLock { $0 += 1 }
        return answers.withLock { list in
            list.count > 1 ? list.removeFirst() : list[0]
        }
    }
}
