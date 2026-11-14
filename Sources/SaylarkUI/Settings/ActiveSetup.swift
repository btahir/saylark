import AppKit
import Observation
import SaylarkCore

/// One thing Saylark still needs before it can paste, as one plain sentence and the one button
/// that fixes it.
public enum ActiveProblem: Hashable, Sendable {
    case accessibility
    case clipboard(ClipboardAccess)
    /// Another dictation app (named) is running and uses the same trigger key.
    case triggerClash(String)

    public var sentence: String {
        switch self {
        case .accessibility:
            "Accessibility is off, so Saylark can't paste."
        case .clipboard(.denied):
            "Clipboard access is off. Saylark reads it to put your own clipboard back after it pastes."
        case .clipboard:
            "Saylark hasn't been allowed to read the clipboard yet. It does this to put your own clipboard back after it pastes."
        case .triggerClash(let app):
            "\(app) is running and also uses Fn, so both would paste. Quit \(app), or pick another key for Saylark."
        }
    }

    public var buttonTitle: String {
        switch self {
        case .accessibility: "Open Settings"
        case .clipboard(.denied): "Open Settings"
        case .clipboard: "Allow"
        case .triggerClash: "Use Right Option"
        }
    }

    /// Every problem in a readiness report, in the order the sentences are shown.
    public static func problems(in readiness: ActiveReadiness) -> [ActiveProblem] {
        var out: [ActiveProblem] = []
        if let app = readiness.triggerClash { out.append(.triggerClash(app)) }
        if !readiness.accessibility { out.append(.accessibility) }
        if readiness.clipboard != .allowed { out.append(.clipboard(readiness.clipboard)) }
        return out
    }
}

/// What Settings and onboarding know about pasting readiness, and how each problem gets fixed.
/// `refresh()` asks the engine (cheap, never prompts). Buttons prompt only because the user clicked.
@MainActor @Observable public final class ActiveSetup {
    public private(set) var readiness: ActiveReadiness
    /// Set after the user answered the clipboard prompt with something other than "Always Allow":
    /// onboarding then shows where to change it in System Settings.
    public private(set) var clipboardAsked = false

    @ObservationIgnored private weak var engine: (any DictationEngine)?
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored var openClipboardSettings: () -> Void

    public init(engine: (any DictationEngine)?, permissions: any PermissionsProviding, settings: AppSettings? = nil,
                openClipboardSettings: @escaping () -> Void = { ActiveSetup.openPasteSettings() }) {
        self.engine = engine
        self.permissions = permissions
        self.settings = settings
        self.openClipboardSettings = openClipboardSettings
        readiness = engine?.activeReadiness() ?? ActiveReadiness()
    }

    public var problems: [ActiveProblem] { ActiveProblem.problems(in: readiness) }

    public func refresh() {
        if let engine { readiness = engine.activeReadiness() }
    }

    /// Runs the fix for one problem, then looks again.
    public func fix(_ problem: ActiveProblem) async {
        switch problem {
        case .accessibility:
            await permissions.request(.accessibility)
        case .clipboard(.denied):
            openClipboardSettings()
        case .clipboard:
            await requestClipboard()
        case .triggerClash:
            settings?.triggerKey = .rightOption
        }
        refresh()
    }

    /// Reads the clipboard once on purpose so macOS asks. Returns the state afterwards.
    @discardableResult
    public func requestClipboard() async -> ClipboardAccess {
        guard let engine else { return readiness.clipboard }
        let state = await engine.requestClipboardAccess()
        readiness.clipboard = state
        clipboardAsked = state != .allowed
        return state
    }

    /// Opens Privacy & Security, where "Paste from Other Apps" lives. An anchor macOS does not know
    /// still opens the Privacy & Security pane.
    public nonisolated static func openPasteSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Renders and tests: a fixed readiness with no engine behind it.
    public static func preview(_ readiness: ActiveReadiness, clipboardAsked: Bool = false) -> ActiveSetup {
        let s = ActiveSetup(engine: nil, permissions: FakePermissions(), openClipboardSettings: {})
        s.readiness = readiness
        s.clipboardAsked = clipboardAsked
        return s
    }
}

/// Apps by bundle ID: the name and icon for the Return list, and the running apps for "Add app".
@MainActor public enum AppDirectory {
    /// Names for the default list when the app is not installed here (renders, other Macs).
    static let known = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.codex": "Codex",
        "com.openai.chat": "ChatGPT",
    ]

    public static func name(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if let name = known[bundleID] { return name }
        return bundleID.split(separator: ".").last.map { String($0).capitalized } ?? bundleID
    }

    /// The list as shown: a default entry for an app that is not installed on this Mac is left
    /// out (it stays in the setting, so it applies if the app is installed later). Apps the user
    /// added are always shown.
    public static func shown(_ listed: [String]) -> [String] {
        listed.filter { id in
            !DictationSettingsKey.defaultSendOnReturnApps.contains(id)
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }

    /// Regular apps that are running now, other than Saylark and those already listed.
    public static func running(excluding listed: [String]) -> [(id: String, name: String)] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set(listed)
        var out: [(id: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != me, seen.insert(id).inserted else { continue }
            out.append((id, app.localizedName ?? name(for: id)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public extension AppSettings {
    /// Adds an app to the Return list (once).
    func addSendOnReturnApp(_ id: String) {
        guard !sendOnReturnApps.contains(id) else { return }
        sendOnReturnApps.append(id)
    }

    func removeSendOnReturnApp(_ id: String) {
        sendOnReturnApps.removeAll { $0 == id }
    }
}
