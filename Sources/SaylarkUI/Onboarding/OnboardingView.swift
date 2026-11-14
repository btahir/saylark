import AppKit
import SaylarkCore
import SwiftUI

/// The first-run window: one idea per step, one main button, art only where it earns its place.
public struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let settingsAccent: PillAccent

    public init(model: OnboardingModel, accent: PillAccent) {
        self.model = model
        self.settingsAccent = accent
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let supervisor = model.supervisor {
                EngineStatusRow(supervisor: supervisor, step: model.step, retry: retry)
            }
            footer
        }
        .frame(width: 520, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.step) {
            // Non-prompting checks, twice a second, only while a permission step is showing.
            guard model.step.permission != nil || model.step == .clipboard else { return }
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func retry() {
        guard let supervisor = model.supervisor, let failure = supervisor.failure else { return }
        switch failure.action {
        case .tryAgain: supervisor.retry()
        case .reopen: model.onReopen?()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            StepLayout(art: .hero("onboarding-welcome"),
                       title: "Talk, and your words appear",
                       message: "Hold \(model.triggerName) and speak. Saylark turns your voice into text on this Mac and pastes it where your cursor is. Your voice and words never leave your Mac.") {
                Button("Get Started") { model.next() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        case .microphone:
            PermissionStep(model: model, permission: .microphone, symbol: "mic",
                           title: "Let Saylark hear you",
                           message: "The mic opens only while you dictate, so the orange dot stays off the rest of the time.",
                           allow: "Allow Microphone", granted: "Microphone is on")
        case .keyboard:
            PermissionStep(model: model, permission: .inputMonitoring, symbol: "keyboard",
                           title: "Let Saylark notice the \(model.triggerName) key",
                           message: "Saylark listens for \(model.triggerName) and Esc, so it knows when you start and stop. It doesn't record what you type.",
                           allow: "Allow Input Monitoring", granted: "Saylark can see the \(model.triggerName) key",
                           note: "macOS lists this as Input Monitoring. It may ask you to reopen Saylark.")
        case .accessibility:
            PermissionStep(model: model, permission: .accessibility, symbol: "keyboard.badge.ellipsis",
                           title: "Let Saylark paste for you",
                           message: "Saylark presses Command V for you, in the field where your cursor is. macOS calls this Accessibility.",
                           allow: "Allow Accessibility", granted: "Saylark can paste",
                           note: "macOS opens System Settings. Switch Saylark on, and this page moves on by itself.")
        case .clipboard:
            ClipboardStep(model: model)
        case .tryIt:
            TryStep(model: model, accent: settingsAccent)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { model.back() }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                .opacity(model.step == .welcome ? 0 : 1)
                .disabled(model.step == .welcome)
            Spacer()
            HStack(spacing: 7) {
                ForEach(model.steps, id: \.self) { s in
                    Circle()
                        .fill(s == model.step ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \((model.steps.firstIndex(of: model.step) ?? 0) + 1) of \(model.steps.count)")
            Spacer()
            // A step that is done shows Continue in its middle instead, so Skip would be the wrong word.
            let noSkip = model.step == .welcome || model.step == .tryIt || model.stepIsDone
            Button(model.step == .tryIt ? "" : "Skip") { model.next() }
                .buttonStyle(.borderless)
                .help("Leave this for now. Saylark asks again when it needs it.")
                .opacity(noSkip ? 0 : 1)
                .disabled(noSkip)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// One quiet line above the footer about the engine: the speech model downloading and preparing (with
/// a progress bar), a permission still missing on the Try-it step, or why it didn't start, with the
/// one action that helps. Nothing at all once Saylark is ready.
struct EngineStatusRow: View {
    let supervisor: EngineSupervisor
    let step: OnboardingModel.Step
    let retry: () -> Void

    var body: some View {
        if let text {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    if let progress = supervisor.progress {
                        ProgressView(value: progress).progressViewStyle(.linear).frame(width: 140)
                    } else if supervisor.failure == nil, supervisor.phase == .starting {
                        ProgressView().controlSize(.small)
                    }
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = supervisor.failure {
                    Button(failure.actionTitle, action: retry).controlSize(.regular)
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var text: String? {
        switch supervisor.phase {
        case .waitingForPermissions:
            // On the permission steps the step itself says what is missing.
            step == .tryIt ? "Saylark can't hear you yet. Go back and finish the permission steps." : nil
        case .running where supervisor.model == .ready, .paused: nil
        default: supervisor.statusLine
        }
    }
}

/// Art, a title, one sentence and the step's controls, centred.
private struct StepLayout<Controls: View>: View {
    enum Art { case hero(String), pill(accent: PillAccent, key: String), symbol(String, PermissionStatus) }

    let art: Art
    let title: String
    let message: String
    @ViewBuilder let controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            artView
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .padding(.top, 26)
            VStack(spacing: 14) { controls }
                .padding(.top, 24)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
    }

    @ViewBuilder private var artView: some View {
        switch art {
        case .hero(let name):
            ArtImage(name: name)
                .aspectRatio(2, contentMode: .fit)
                .frame(maxWidth: 440)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .pill(let accent, let key):
            // What a take looks like: the real pill, talking, as it comes by default (seeds, no words).
            VStack(spacing: 14) {
                Keycap(key).scaleEffect(1.4)
                PillPreview(theme: PillTheme(accent: accent), primeSeconds: 2.6)
                    .frame(width: 360, height: 64)
            }
            .padding(.top, 44)
        case .symbol(let name, let status):
            ZStack {
                Circle().fill(Color.primary.opacity(0.06)).frame(width: 96, height: 96)
                Image(systemName: status == .granted ? "checkmark" : name)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(status == .granted ? Color.green : Color.primary.opacity(0.8))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.top, 52)
        }
    }
}

private struct PermissionStep: View {
    let model: OnboardingModel
    let permission: Permission
    let symbol: String
    let title: String
    let message: String
    let allow: String
    let granted: String
    var note: String?

    var body: some View {
        let status = model.status(permission)
        StepLayout(art: .symbol(symbol, status), title: title, message: message) {
            switch status {
            case .granted:
                Label(granted, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 32)
                ContinueButton(model: model)
            case .notDetermined:
                Button(allow) { model.requestCurrent() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case .denied:
                VStack(spacing: 10) {
                    Button("Open System Settings") { model.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Text("It was turned off. Switch Saylark on in Privacy & Security, and this page moves on by itself.")
                        .settingsFootnote()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }
            if let note, status == .notDetermined {
                Text(note).settingsFootnote().multilineTextAlignment(.center)
            }
        }
    }
}

/// The last step: say something and see it land in the field, with the clash fix when another
/// dictation app also listens to Fn.
private struct TryStep: View {
    @Bindable var model: OnboardingModel
    let accent: PillAccent

    var body: some View {
        StepLayout(art: .pill(accent: accent, key: model.settings?.triggerKey.keycap ?? "fn"),
                   title: "Try it",
                   message: "Hold \(model.triggerName) and say anything. Let go, and your words land in the box.") {
            PracticeField(text: $model.practiceText)
            if let app = model.triggerClash {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(app) is running and also uses Fn, so both would paste. Quit \(app), or pick another key for Saylark.")
                        .settingsFootnote()
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use Right Option") { model.useRightOption() }.controlSize(.small)
                }
                .frame(width: 400)
            }
            Button("Done") { model.next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Why Saylark reads the clipboard, the button that makes macOS ask, and where to change the answer.
private struct ClipboardStep: View {
    let model: OnboardingModel

    var body: some View {
        StepLayout(art: .symbol("doc.on.clipboard", model.clipboard == .allowed ? .granted : .notDetermined),
                   title: "Let Saylark use your clipboard",
                   message: "To paste, Saylark puts your words on the clipboard for a moment. It reads your clipboard first so it can put your own back afterwards.") {
            if model.clipboard == .allowed {
                Label("Clipboard access is on", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 32)
                ContinueButton(model: model)
            } else if model.clipboardNeedsSettings {
                VStack(spacing: 10) {
                    Button("Open System Settings") { model.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Text("In Privacy & Security, open Paste from Other Apps, find Saylark and choose Always Allow. This page moves on by itself.")
                        .settingsFootnote()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else {
                VStack(spacing: 10) {
                    Button("Allow Clipboard Access") { model.requestClipboard() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Text("macOS asks once. Choose Allow, or Always Allow so it doesn't ask again.")
                        .settingsFootnote()
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

/// On a step that already has what it needs: move on now (the step also moves on by itself, unless
/// the user came back to it with Back).
private struct ContinueButton: View {
    let model: OnboardingModel

    var body: some View {
        Button("Continue") { model.next() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

/// Where practice takes land: a real text field, so the paste goes in.
private struct PracticeField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(6)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Your words will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { focused = true }
        .frame(width: 400, height: 76)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// Brand art shipped in the app bundle's Resources (or packaging/Art when run from the repo).
struct ArtImage: View {
    let name: String

    var body: some View {
        if let image = BrandArt.image(name) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color(white: 0.09))
        }
    }
}

@MainActor public enum BrandArt {
    private static var cache: [String: NSImage] = [:]

    public static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let candidates = [Bundle.main.url(forResource: name, withExtension: "png"),
                          URL(fileURLWithPath: "packaging/Art/\(name).png")]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}
