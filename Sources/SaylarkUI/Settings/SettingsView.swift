import AppKit
import SaylarkCore
import ServiceManagement
import SwiftUI

/// Launch at login, behind a seam so renders and tests never register a login item.
@MainActor public struct LoginItem {
    public enum Status: Sendable, Equatable {
        case off, on
        /// Registered, but macOS wants the user to allow it in System Settings > General > Login Items.
        case needsApproval
    }

    public var status: () -> Status
    public var setEnabled: (Bool) throws -> Void
    public var openLoginItemsSettings: () -> Void

    public init(status: @escaping () -> Status, setEnabled: @escaping (Bool) throws -> Void,
                openLoginItemsSettings: @escaping () -> Void = {}) {
        self.status = status
        self.setEnabled = setEnabled
        self.openLoginItemsSettings = openLoginItemsSettings
    }

    /// The app's own login item (`SMAppService.mainApp`). Changed only from the Settings toggle.
    public static let system = LoginItem(
        status: {
            switch SMAppService.mainApp.status {
            case .enabled: .on
            case .requiresApproval: .needsApproval
            default: .off
            }
        },
        setEnabled: { on in
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        },
        openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() })

    public static func fake(_ on: Bool = false) -> LoginItem {
        var state = on
        return LoginItem(status: { state ? .on : .off }, setEnabled: { state = $0 })
    }
}

/// One page, about eight items. Everything rarer sits under Advanced.
public struct SettingsView: View {
    @Bindable var settings: AppSettings
    let inputList: InputList
    let loginItem: LoginItem
    /// What pasting still needs. Nil in tests that do not care.
    let setup: ActiveSetup?
    @ViewState private var loginStatus: LoginItem.Status
    @ViewState private var loginProblem: String?
    @ViewState private var showAdvanced: Bool

    public init(settings: AppSettings, inputs: InputList, loginItem: LoginItem, setup: ActiveSetup? = nil, showAdvanced: Bool = false) {
        self.settings = settings
        inputList = inputs
        self.loginItem = loginItem
        self.setup = setup
        _loginStatus = ViewState(initialValue: loginItem.status())
        _loginProblem = ViewState(initialValue: nil)
        _showAdvanced = ViewState(initialValue: showAdvanced)
    }

    /// A fixed device list (renders, tests).
    public init(settings: AppSettings, inputs: [AudioInput], loginItem: LoginItem, setup: ActiveSetup? = nil, showAdvanced: Bool = false) {
        self.init(settings: settings, inputs: InputList(inputs), loginItem: loginItem, setup: setup, showAdvanced: showAdvanced)
    }

    private var inputs: [AudioInput] { inputList.inputs }

    public var body: some View {
        Form {
            Section {
                if let setup {
                    ForEach(setup.problems, id: \.self) { problem in
                        ProblemRow(problem: problem) { Task { await setup.fix(problem) } }
                    }
                }
                // The hint sits under the label, like the toggles' descriptions, not squeezed beside the picker.
                Picker(selection: $settings.triggerKey) {
                    ForEach(TriggerKey.userChoices, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Shortcut")
                    Text(settings.triggerKey.gestureHint)
                }
                Picker("Microphone", selection: $settings.microphoneUID) {
                    Text("Automatic").tag(String?.none)
                    if !inputs.isEmpty { Divider() }
                    ForEach(inputs) { Text($0.name).tag(Optional($0.uid)) }
                }
                // Where the words go is this section's subject, so the no-text-field choice lives here.
                Toggle(isOn: $settings.copyWhenNoField) {
                    Text("Copy when there's no text field")
                    Text("Puts the text on your clipboard right away. Off: a card shows it with a Copy button.")
                }
            } footer: {
                Text("Saylark pastes your words where your cursor is.").settingsFootnote()
            }

            Section {
                Picker("Return sends", selection: $settings.sendOnReturn) {
                    ForEach(SendOnReturn.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.sendOnReturn == .listedApps {
                    ForEach(AppDirectory.shown(settings.sendOnReturnApps), id: \.self) { id in
                        SendAppRow(bundleID: id) { settings.removeSendOnReturnApp(id) }
                    }
                    let others = AppDirectory.running(excluding: settings.sendOnReturnApps)
                    HStack {
                        Menu {
                            if others.isEmpty {
                                Text("No other apps are open")
                            }
                            ForEach(others, id: \.id) { app in
                                Button(app.name) { settings.addSendOnReturnApp(app.id) }
                            }
                        } label: {
                            Label("Add App", systemImage: "plus")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add an app that's open now")
                        Spacer()
                    }
                }
            } footer: {
                Text(SendOnReturn.explanation).settingsFootnote()
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Voice visual")
                    HStack(spacing: 10) {
                        ForEach(VoiceVisualKind.allCases, id: \.self) { kind in
                            VisualTile(kind: kind, theme: theme(kind), selected: settings.voiceVisual == kind) {
                                settings.voiceVisual = kind
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                Toggle(isOn: $settings.liveWords) {
                    Text("Show words while you talk")
                    Text("Off keeps the pill small: just the voice visual.")
                }
                LabeledContent("Accent") {
                    HStack(spacing: 10) {
                        ForEach(PillAccent.userChoices, id: \.self) { accent in
                            AccentSwatch(accent: accent, selected: settings.accent == accent) { settings.accent = accent }
                        }
                    }
                }
            }

            Section {
                Picker("Keep audio for", selection: $settings.keepAudio) {
                    ForEach(AudioRetention.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Launch at login", isOn: Binding(get: { loginStatus != .off }, set: { setLaunchAtLogin($0) }))
                if let loginProblem {
                    Text(loginProblem).settingsFootnote()
                } else if loginStatus == .needsApproval {
                    HStack {
                        Text("macOS needs you to allow Saylark in Login Items.").settingsFootnote()
                        Spacer()
                        Button("Open Login Items") { loginItem.openLoginItemsSettings() }.controlSize(.small)
                    }
                }
                Toggle(isOn: $settings.sounds) {
                    Text("Sounds")
                    Text("A quiet tone when a take starts and stops.")
                }
            }

            Section {
                // A row that is one button: click anywhere on it (or press Space with keyboard
                // navigation) to show or hide the rarer options. They open as ordinary rows of this
                // section, so they get the form's separators and spacing.
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                            .frame(width: 12)
                        Text("Advanced")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advanced")
                .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
                .accessibilityHint(showAdvanced ? "Hides the advanced settings" : "Shows the advanced settings")
                if showAdvanced {
                    Toggle(isOn: $settings.keepMicReady) {
                        Text("Keep mic ready")
                        Text("Starts a little faster, but the orange mic dot stays on.")
                    }
                    Toggle(isOn: $settings.paragraphsFromPauses) {
                        Text("Paragraphs from pauses")
                        Text("A long pause in a long take becomes a paragraph break.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        // The window is kept between openings, so look again each time it comes forward: a mic plugged
        // in meanwhile, or Login Items changed in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            inputList.refresh()
            setup?.refresh()
            loginStatus = loginItem.status()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try loginItem.setEnabled(on)
            loginProblem = nil
        } catch {
            loginProblem = "Saylark couldn't change this: \(error.localizedDescription)"
        }
        loginStatus = loginItem.status()
    }

    private func theme(_ kind: VoiceVisualKind) -> PillTheme {
        var t = settings.pillTheme
        t.visual = kind
        t.liveWords = false
        return t
    }
}

/// One thing pasting needs: a sentence and its one button, inline in the form.
private struct ProblemRow: View {
    let problem: ActiveProblem
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(problem.sentence)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(problem.buttonTitle, action: fix).controlSize(.small)
        }
    }
}

/// An app in the Return list: icon, name, and a button to take it off.
private struct SendAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: bundleID, appName: AppDirectory.name(for: bundleID))
                .frame(width: 20, height: 20)
            Text(AppDirectory.name(for: bundleID))
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove \(AppDirectory.name(for: bundleID))")
        }
    }
}

/// A live preview of one voice visual. Click to choose it.
private struct VisualTile: View {
    let kind: VoiceVisualKind
    let theme: PillTheme
    let selected: Bool
    let choose: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                PillPreview(theme: theme)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering && !selected ? 0.08 : 0.05)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(selected ? 0.7 : hovering ? 0.25 : 0.08), lineWidth: selected ? 1.5 : 1)
                    }
                Text(kind.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kind.blurb)
        .accessibilityLabel("\(kind.title): \(kind.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AccentSwatch: View {
    let accent: PillAccent
    let selected: Bool
    let choose: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(Color(cgColor: accent.color))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.55 : hovering ? 0.2 : 0), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(accent.title)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small key, drawn like the ones in System Settings' keyboard pane.
struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
    }
}

extension Text {
    func settingsFootnote() -> some View {
        font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
