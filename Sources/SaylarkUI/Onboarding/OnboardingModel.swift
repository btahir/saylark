import AppKit
import Observation
import SaylarkCore

/// First run (PLAN §2.5): welcome, microphone, keyboard access, accessibility, the clipboard, then
/// try it. Permission state is polled with non-prompting checks while a
/// permission step is showing, and the step moves on by itself once the permission is granted.
/// Prompts happen only from the step's button.
@MainActor @Observable public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, microphone, keyboard, accessibility, clipboard, tryIt

        var permission: Permission? {
            switch self {
            case .microphone: .microphone
            case .keyboard: .inputMonitoring
            case .accessibility: .accessibility
            default: nil
            }
        }
    }

    public var step: Step
    public private(set) var statuses: [Permission: PermissionStatus] = [:]
    /// The practice field's text. It is a real text field: the paste lands in it.
    public var practiceText = ""
    @ObservationIgnored let permissions: any PermissionsProviding
    /// Where the engine is (waiting, loading the model, running, failed). Shown under the step.
    @ObservationIgnored public let supervisor: EngineSupervisor?
    /// The user's settings, for the trigger key. Nil in tests that do not need them.
    @ObservationIgnored public let settings: AppSettings?
    /// What pasting needs: the clipboard step and the clash warning read it.
    @ObservationIgnored public let setup: ActiveSetup?
    @ObservationIgnored public var onFinish: (() -> Void)?
    /// The "Reopen Saylark" button (macOS only lets a running app see the keyboard after a reopen).
    @ObservationIgnored public var onReopen: (() -> Void)?
    /// Called after every permission re-read, so the app can start the engine the moment access exists.
    @ObservationIgnored public var onRefresh: (() -> Void)?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    /// Set by Back: the user came back to look at a step, so it must not move on by itself again
    /// (a granted step used to bounce forward 0.7 s after Back). Its Continue button moves on.
    @ObservationIgnored private var holdAdvance = false

    public init(permissions: any PermissionsProviding, step: Step = .welcome, supervisor: EngineSupervisor? = nil,
                settings: AppSettings? = nil, setup: ActiveSetup? = nil) {
        self.permissions = permissions
        self.step = step
        self.supervisor = supervisor
        self.settings = settings
        self.setup = setup
        refresh()
    }

    public var steps: [Step] { Step.allCases }

    public var triggerName: String { settings?.triggerKey.title ?? TriggerKey.fn.title }

    /// Where the window opens. First run starts at the welcome. After that it only opens because
    /// something is missing, so it goes straight to the step that fixes it.
    public static func firstStep(onboarded: Bool, missing: [Permission], startFailed: Bool = false) -> Step {
        if !onboarded { return .welcome }
        if missing.contains(.microphone) { return .microphone }
        if missing.contains(.inputMonitoring) { return .keyboard }
        if missing.contains(.accessibility) { return .accessibility }
        return startFailed ? .tryIt : .welcome
    }

    public func status(_ p: Permission) -> PermissionStatus { statuses[p] ?? .notDetermined }

    public var clipboard: ClipboardAccess { setup?.readiness.clipboard ?? .allowed }

    /// True once macOS was asked and the answer was not "Always Allow".
    public var clipboardNeedsSettings: Bool { clipboard == .denied || (setup?.clipboardAsked ?? false) }

    /// Another dictation app on the same trigger key, shown on the last step.
    public var triggerClash: String? {
        guard settings?.triggerKey ?? .fn == .fn else { return nil }
        return setup?.readiness.triggerClash
    }

    /// True when the current step has what it needs (its Continue button shows instead of Skip).
    public var stepIsDone: Bool {
        if let p = step.permission { return status(p) == .granted }
        if step == .clipboard { return clipboard == .allowed }
        return false
    }

    /// Re-reads every permission (non-prompting). Moves on when the current step's permission arrives.
    public func refresh() {
        for p in Permission.allCases { statuses[p] = permissions.status(p) }
        setup?.refresh()
        onRefresh?()
        if stepIsDone, !holdAdvance, advanceTask == nil {
            let current = step
            // A short beat so the "granted" state is seen before the step changes.
            advanceTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, self.step == current else { self.advanceTask = nil; return }
                self.advanceTask = nil
                self.next()
            }
        }
    }

    public func next() {
        advanceTask?.cancel()
        advanceTask = nil
        holdAdvance = false
        let list = steps
        if let i = list.firstIndex(of: step), i + 1 < list.count {
            step = list[i + 1]
            refresh()
        } else if step != .tryIt, let n = list.first(where: { $0.rawValue > step.rawValue }) {
            step = n
            refresh()
        } else {
            onFinish?()
        }
    }

    public func back() {
        advanceTask?.cancel()
        advanceTask = nil
        let list = steps
        if let p = list.last(where: { $0.rawValue < step.rawValue }) {
            step = p
            holdAdvance = true
        }
    }

    /// The step's main button: the system prompt the first time, System Settings after a denial.
    public func requestCurrent() {
        if step == .clipboard { requestClipboard(); return }
        guard let p = step.permission else { return }
        Task {
            await permissions.request(p)
            refresh()
        }
    }

    /// Reads the clipboard once on purpose, so macOS shows its prompt.
    public func requestClipboard() {
        guard let setup else { return }
        Task {
            await setup.requestClipboard()
            refresh()
        }
    }

    public func openSettings() {
        if step == .clipboard { setup?.openClipboardSettings(); return }
        guard let p = step.permission else { return }
        permissions.openSystemSettings(p)
    }

    /// The clash fix: another key for Saylark, so both apps can run.
    public func useRightOption() {
        settings?.triggerKey = .rightOption
        setup?.refresh()
    }
}
