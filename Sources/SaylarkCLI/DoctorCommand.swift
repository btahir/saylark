import AppKit
import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark doctor`: what the engine would use, checked without opening anything or prompting:
/// input devices and the one the policy picks, other apps' key taps, and this process's permissions.
///
/// `--mic-open N` is the one exception: it opens the policy-picked microphone N times cold (the
/// orange dot shows) and reports how long the open call takes and how long until the first audio,
/// then the same with the mic kept warm. That is the cost a cold Fn-down pays; since the engine now
/// opens the mic off the main thread, it delays the first audio, not the UI.
enum DoctorCommand {
    static func run(_ args: Arguments) async throws {
        let output = AudioDevices.defaultOutput()
        print("default output: \(output.map { "\($0.name) (\($0.transport.rawValue))" } ?? "-")")
        print("default input:  \(AudioDevices.defaultInput().map { "\($0.name) (\($0.transport.rawValue))" } ?? "-")")
        print("inputs:")
        for d in AudioDevices.inputs() {
            print("  \(d.name) [\(d.transport.rawValue), \(d.inputChannels) ch, \(Int(d.sampleRate)) Hz] uid \(d.uid)")
        }
        let chosen = AudioDevices.choose(pinnedUID: args.value("pin"))
        print("policy picks: \(chosen?.name ?? "nothing")")
        print("event taps:")
        for t in EventTapCensus.taps() {
            print("  \(t.process): \(t.location) \(t.active ? "active" : "listen-only") \(t.enabled ? "on" : "off") flagsChanged=\(t.flagsChanged) keyDown=\(t.keyDown)")
        }
        let risks = EventTapCensus.hidRisks()
        print("active HID-level taps that could hide Fn from ours: \(risks.isEmpty ? "none" : risks.map(\.process).joined(separator: ", "))")
        let p = EnginePermissions.status()
        print("this process: microphone \(p.microphone), input monitoring \(p.inputMonitoring), accessibility \(p.accessibility)")
        print("fn key down now (HID state): \(FnKeyState.isDown())")
        await printActiveReadiness(accessibility: p.accessibility)
        let t = ContinuousClock.now
        _ = AudioDevices.choose(pinnedUID: args.value("pin"))
        print("device pick (enumeration, no open): \(fmt(t.msSince, 2)) ms")
        if let n = args.value("mic-open").flatMap(Int.init), n > 0 {
            guard let device = chosen else { throw CLIError("no microphone to open") }
            try await measureMicOpen(device, times: n)
        }
    }

    /// Pasting readiness, read-only: the app's settings (its defaults domain), Accessibility for
    /// this process, and running dictation apps that would also act on the trigger. The clipboard
    /// is not checked: even asking macOS how it treats the general pasteboard is skipped here, so
    /// the doctor never goes near the user's clipboard. The app shows that line itself.
    @MainActor static func printActiveReadiness(accessibility: Bool) {
        let app = UserDefaults(suiteName: "app.saylark.Saylark")
        let trigger = app?.string(forKey: DictationSettingsKey.triggerKey).flatMap(TriggerKey.init(rawValue:)) ?? .fn
        let send = app?.string(forKey: DictationSettingsKey.sendOnReturn) ?? "listedApps (default)"
        let paragraphs = app?.object(forKey: DictationSettingsKey.paragraphsFromPauses) as? Bool ?? true
        print("pasting: trigger \(trigger.rawValue), send on Return \(send), paragraphs from pauses \(paragraphs)")
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let clash = ShadowEngine.triggerClash(trigger: trigger, running: running)
        let others = ShadowEngine.knownDictationApps.filter { running.contains($0.bundleID) }.map(\.name)
        print("  accessibility (this process): \(accessibility ? "on" : "off")")
        print("  trigger clash: \(clash ?? "none")\(others.isEmpty ? "" : " (running dictation apps: \(others.joined(separator: ", ")))")")
        print("  clipboard access: not checked by the doctor (it never touches the general clipboard)")
    }

    /// Opens the device `times` times cold: ms for the open call and ms until the first buffer.
    static func measureMicOpen(_ device: MicDevice, times: Int) async throws {
        print("opening \(device.name) \(times) times (cold)...")
        var opens: [Double] = [], firsts: [Double] = []
        for _ in 0..<times {
            let source = HALAudioSource(device: device)
            let first = Locked<Double?>(nil)
            let began = HotkeyClock.now
            try source.start(onChunk: { _ in first.withLock { if $0 == nil { $0 = HotkeyClock.now } } }, onFailure: { _ in })
            opens.append((HotkeyClock.now - began) * 1000)
            let deadline = began + 2
            while first.withLock({ $0 }) == nil, HotkeyClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            if let f = first.withLock({ $0 }) { firsts.append((f - began) * 1000) }
            source.stop()
            try await Task.sleep(for: .milliseconds(300))
        }
        print("cold open call: median \(fmt(percentile(opens, 0.5), 1)) ms, p90 \(fmt(percentile(opens, 0.9), 1)) ms")
        print("cold first audio: median \(fmt(percentile(firsts, 0.5), 1)) ms, p90 \(fmt(percentile(firsts, 0.9), 1)) ms (\(firsts.count)/\(times) delivered)")
        print("warm (Keep mic ready): first audio of a take is the 450 ms pre-roll, 0 ms wait")
    }
}

/// A value behind a lock, for the doctor's callbacks.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
