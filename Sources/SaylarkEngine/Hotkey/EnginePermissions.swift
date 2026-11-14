import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics

/// What the engine can do right now, checked without prompting.
public struct PermissionsStatus: Sendable, Equatable {
    public enum Mic: Sendable, Equatable { case granted, notDetermined, denied }

    public var microphone: Mic
    /// TCC "ListenEvent" (Input Monitoring): needed by the listen-only Fn tap and the HID fallback.
    public var inputMonitoring: Bool
    /// TCC "Accessibility": the NSEvent fallback monitor (shadow) and pasting (active, M2).
    public var accessibility: Bool

    /// Shadow mode can run: a mic and at least one way to hear Fn.
    public var shadowReady: Bool { microphone == .granted && (inputMonitoring || accessibility) }
}

/// Permission checks for onboarding. `status()` never shows a prompt and is safe to poll.
/// The `request…` calls show the system prompt (first time) and must only run from a user click.
public enum EnginePermissions {
    public static func status() -> PermissionsStatus {
        let mic: PermissionsStatus.Mic
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
        return PermissionsStatus(
            microphone: mic,
            inputMonitoring: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    /// Shows the microphone prompt the first time; returns whether access was granted.
    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the Input Monitoring prompt the first time (and adds Saylark to the list in System
    /// Settings). Returns true only if already granted; a grant needs no relaunch for new taps.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    /// Shows the Accessibility prompt the first time.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public enum Pane: String, Sendable {
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
    }

    @MainActor
    public static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
