import Foundation
import Observation
import SaylarkCore

/// Why the engine did not start, in a sentence a person can act on, with the one action that helps.
public struct StartFailure: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Try `start()` again (the model download or load failed).
        case tryAgain
        /// macOS only lets a running app see the keyboard after the permission is granted and the app reopens.
        case reopen
    }

    public var message: String
    public var action: Action

    public var actionTitle: String {
        switch action {
        case .tryAgain: "Try Again"
        case .reopen: "Reopen Saylark"
        }
    }

    /// Sorts an error from `engine.start()` into one of the two failures we can explain.
    /// `model` is the engine's last reported model state: a failed load says so before `start()` throws.
    public static func classify(_ error: any Error, model: ModelState) -> StartFailure {
        if case .failed = model {
            return StartFailure(message: "Saylark couldn't load its speech model. Check your internet connection, then try again.", action: .tryAgain)
        }
        let text = String(describing: error).lowercased()
        if ["input monitoring", "accessibility", "event tap", "keyboard"].contains(where: text.contains) {
            return StartFailure(message: "macOS hasn't let Saylark see the Fn key yet. Reopening Saylark usually fixes it.", action: .reopen)
        }
        return StartFailure(message: "Saylark couldn't start. Try again, and reopen it if that doesn't help.", action: .tryAgain)
    }
}

/// Starts the engine as soon as the permissions it needs exist, and reports where it is: waiting for
/// permission, loading the speech model (download, compile, warm-up), running, paused or failed.
///
/// The engine used to start only after onboarding finished, so the "Try it" step never received a
/// take, and nothing showed the model loading while Fn was silently ignored.
@MainActor @Observable public final class EngineSupervisor {
    public enum Phase: Equatable, Sendable {
        case waitingForPermissions
        case starting
        case running
        case paused
        case failed(StartFailure)
    }

    public private(set) var phase: Phase = .waitingForPermissions
    public private(set) var model: ModelState = .notLoaded

    @ObservationIgnored let engine: any DictationEngine
    @ObservationIgnored let permissions: any PermissionsProviding
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(engine: any DictationEngine, permissions: any PermissionsProviding) {
        self.engine = engine
        self.permissions = permissions
    }

    /// Begins following the engine's model state. Safe to call once, before `startIfPossible()`.
    public func follow() {
        guard following == nil else { return }
        let stream = engine.modelStates()
        following = Task { [weak self] in
            for await state in stream { self?.model = state }
        }
    }

    /// Permissions the engine needs and that are not granted yet.
    public var missingPermissions: [Permission] {
        permissions.required.filter { permissions.status($0) != .granted }
    }

    /// True once Fn will start a take.
    public var isListening: Bool { phase == .running && model == .ready }

    /// Starts the engine if every needed permission is granted. Cheap; call it whenever permissions may have changed.
    public func startIfPossible() {
        switch phase {
        case .starting, .running, .paused: return
        case .waitingForPermissions, .failed: break
        }
        guard missingPermissions.isEmpty else {
            phase = .waitingForPermissions
            return
        }
        phase = .starting
        starting = Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.start()
                if phase == .starting { phase = .running }
            } catch {
                guard phase == .starting else { return }
                // The engine reports a failed model just before it throws; let that update arrive.
                await Task.yield()
                NSLog("Saylark: engine did not start: \(error)")
                phase = .failed(StartFailure.classify(error, model: model))
            }
        }
    }

    /// Renders only: shows a state with no engine behind it.
    public func preview(phase: Phase, model: ModelState) {
        self.phase = phase
        self.model = model
    }

    /// Waits for a start in flight to finish (tests).
    func settle() async { await starting?.value }

    /// The failure's action, or the plain retry.
    public func retry() {
        starting?.cancel()
        phase = .waitingForPermissions
        startIfPossible()
    }

    public func pause() {
        starting?.cancel()
        engine.stop()
        phase = .paused
    }

    public func resume() {
        guard phase == .paused else { return }
        phase = .waitingForPermissions
        startIfPossible()
    }

    // MARK: What to say

    /// One quiet line for the menu and onboarding while the app is not ready to take Fn. Nil when ready or paused.
    public var statusLine: String? {
        switch phase {
        case .running where model == .ready, .paused: return nil
        case .waitingForPermissions: return "Needs permission to start"
        case .failed(let failure): return failure.message
        case .starting, .running: return Self.describe(model)
        }
    }

    /// 0...1 while the model is downloading or compiling.
    public var progress: Double? {
        switch model {
        case .downloading(let p), .compiling(let p): max(0, min(1, p))
        default: nil
        }
    }

    public var failure: StartFailure? {
        if case .failed(let f) = phase { f } else { nil }
    }

    static func describe(_ state: ModelState) -> String {
        func pct(_ p: Double) -> Int { Int((max(0, min(1, p)) * 100).rounded()) }
        switch state {
        case .notLoaded: return "Starting"
        case .downloading(let p): return "Downloading the speech model, \(pct(p))%"
        case .compiling(let p): return "Preparing the speech model for this Mac, \(pct(p))%"
        case .warming: return "Almost ready"
        case .ready: return "Starting"
        case .failed: return "The speech model didn't load"
        }
    }

    /// What the pill says when Fn is pressed and Saylark can't take it yet. Nil when it can.
    public var fnPressMessage: String? {
        if isListening || phase == .paused { return nil }
        switch phase {
        case .waitingForPermissions: return "Saylark needs permission first. Open its menu."
        case .failed: return "Saylark didn't start. Open its menu."
        default:
            switch model {
            case .downloading(let p): return "Downloading the speech model, \(Int((max(0, min(1, p)) * 100).rounded()))%."
            case .compiling(let p): return "Preparing the speech model, \(Int((max(0, min(1, p)) * 100).rounded()))%."
            case .failed: return "The speech model didn't load. Open the menu."
            default: return "Still getting ready. Try again in a moment."
            }
        }
    }
}

extension ModelState {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
