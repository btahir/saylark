import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import SaylarkCore

/// The macOS privacy permissions Saylark can need.
public enum Permission: String, CaseIterable, Sendable {
    case microphone
    /// "Input Monitoring" (TCC ListenEvent): the listen-only Fn hook and Esc.
    case inputMonitoring
    /// "Accessibility": pasting and reading the focused field.
    case accessibility

    var settingsAnchor: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    /// Never asked: the request shows the system prompt.
    case notDetermined
    /// Turned off: only System Settings can turn it on.
    case denied
}

/// Permission checks and requests for onboarding and error recovery.
///
/// The engine contract (`DictationEngine`) has no permission calls yet, so this lives on the UI side.
/// `status` never prompts and is safe to poll; `request` is called only from a button the user clicks.
@MainActor public protocol PermissionsProviding: AnyObject {
    /// What the engine needs before it starts: microphone, Input Monitoring and Accessibility.
    var required: [Permission] { get }
    func status(_ permission: Permission) -> PermissionStatus
    /// Shows the system prompt when the permission was never asked, otherwise opens System Settings.
    func request(_ permission: Permission) async
    func openSystemSettings(_ permission: Permission)
}

/// The real checks. Every status call is a non-prompting preflight.
@MainActor public final class SystemPermissions: PermissionsProviding {
    public init() {}

    public var required: [Permission] { Permission.allCases }

    public func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .inputMonitoring:
            // No "never asked" state is exposed; the request call shows the prompt only the first time.
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined
        }
    }

    public func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            if status(.microphone) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                openSystemSettings(.microphone)
            }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSystemSettings(.inputMonitoring) }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSystemSettings(.accessibility) }
        }
    }

    public func openSystemSettings(_ permission: Permission) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }
}

/// Fixed answers for renders, tests and `--fake-engine` runs. `request` grants instantly.
@MainActor public final class FakePermissions: PermissionsProviding {
    public var states: [Permission: PermissionStatus]

    public init(_ states: [Permission: PermissionStatus] = [:]) {
        self.states = states
    }

    public var required: [Permission] { Permission.allCases }

    public func status(_ permission: Permission) -> PermissionStatus { states[permission] ?? .granted }
    public func request(_ permission: Permission) async { states[permission] = .granted }
    public func openSystemSettings(_ permission: Permission) { states[permission] = .granted }
}
