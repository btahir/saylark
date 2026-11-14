import SaylarkCore
import SaylarkEngine
import SaylarkUI

/// The UI's permission seam backed by the engine's own checks (`EnginePermissions`), so onboarding
/// and the engine agree on what "ready" means. Status calls never prompt.
@MainActor final class EnginePermissionsProvider: PermissionsProviding {
    var required: [Permission] { [.microphone, .inputMonitoring, .accessibility] }

    func status(_ permission: Permission) -> PermissionStatus {
        let s = EnginePermissions.status()
        switch permission {
        case .microphone:
            switch s.microphone {
            case .granted: return .granted
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            }
        case .inputMonitoring:
            // The engine can also hear Fn through its Accessibility fallback (`shadowReady`).
            return s.inputMonitoring || s.accessibility ? .granted : .notDetermined
        case .accessibility:
            return s.accessibility ? .granted : .notDetermined
        }
    }

    func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            if status(.microphone) == .denied { openSystemSettings(.microphone) } else { await EnginePermissions.requestMicrophone() }
        case .inputMonitoring:
            if !EnginePermissions.requestInputMonitoring() { openSystemSettings(.inputMonitoring) }
        case .accessibility:
            if !EnginePermissions.requestAccessibility() { openSystemSettings(.accessibility) }
        }
    }

    func openSystemSettings(_ permission: Permission) {
        switch permission {
        case .microphone: EnginePermissions.openSettings(.microphone)
        case .inputMonitoring: EnginePermissions.openSettings(.inputMonitoring)
        case .accessibility: EnginePermissions.openSettings(.accessibility)
        }
    }
}
