import AppKit
import SaylarkCore
import SwiftUI

/// `SaylarkApp --ui-render --out launch/m1`: renders every screen (the Saylark window and its tabs,
/// the settings form, onboarding, the menu) to PNG with fake data, in light and dark, for design review. Windows are built exactly as the app builds them but never ordered on
/// screen; each is drawn with `cacheDisplay`, chrome included. No engine, mic, clipboard or prompts.
@MainActor public enum UIRenderCommand {
    public static func run(outDir: URL) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var made: [String] = []
        func save(_ name: String, _ image: NSBitmapImageRep?) {
            guard let data = image?.representation(using: .png, properties: [:]) else { print("\(name): failed"); return }
            try? data.write(to: outDir.appendingPathComponent(name))
            made.append(name)
        }

        let defaults = UserDefaults(suiteName: "saylark.render.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let accent = Color(cgColor: settings.accent.controlColor)

        let inputs = [AudioInput(uid: "q2u", name: "Samson Q2U Microphone"), AudioInput(uid: "builtin", name: "MacBook Pro Microphone")]

        // The Saylark window, each tab. Dictionaries are temp files, never the user's.
        var tempFiles: [URL] = []
        defer { for url in tempFiles { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        func main(_ tab: MainTab, dictionary text: String = SampleDictionary.text) -> (AppWindow, MainModel) {
            let url = SampleDictionary.write(text)
            tempFiles.append(url)
            let model = MainModel(library: libraryModel(), dictionary: DictionaryModel(url: url), tab: tab, accent: accent)
            let view = MainView(model: model) {
                SettingsView(settings: settings, inputs: inputs, loginItem: .fake(), setup: .preview(ActiveReadiness()))
            }
            return (Windows.main(view.environment(\.controlActiveState, .key), remembersFrame: false), model)
        }
        // Home: every way a take can end, one take open with the player part-way, one row hovered.
        for dark in [false, true] {
            let (window, model) = main(.home)
            save("main-home-\(dark ? "dark" : "light").png", snapshot(window, dark: dark, settle: { prepareLibrary(model.library) }))
        }
        do {
            let (window, model) = main(.home)
            save("main-home-search-light.png", snapshot(window, dark: false, settle: { model.library.query = "vercel" }))
        }
        do {
            // The pointer over a take that went in: Copy, Paste again, Play.
            let (window, model) = main(.home)
            save("main-home-hover-dark.png", snapshot(window, dark: true, settle: { model.library.hoverPreview = model.library.all[1].id }))
        }
        // Dictionary: the list, a hovered row, editing, adding with a problem, skipped lines, empty, search.
        for dark in [false, true] {
            let (window, model) = main(.dictionary)
            save("main-dictionary-\(dark ? "dark" : "light").png", snapshot(window, dark: dark, settle: { model.dictionary.hoverPreview = "postgres" }))
        }
        do {
            let (window, model) = main(.dictionary)
            save("main-dictionary-edit-light.png", snapshot(window, dark: false, settle: {
                model.dictionary.load()
                if let e = model.dictionary.entries.first(where: { $0.term == "Tailwind" }) { model.dictionary.startEditing(e) }
            }))
        }
        do {
            let (window, model) = main(.dictionary)
            save("main-dictionary-add-dark.png", snapshot(window, dark: true, settle: {
                model.dictionary.editor = DictionaryModel.Editor(term: "Foo, Bar", heardAs: "foo bar")
                model.dictionary.commit()
            }))
        }
        do {
            let (window, _) = main(.dictionary, dictionary: SampleDictionary.withProblems)
            save("main-dictionary-skipped-light.png", snapshot(window, dark: false, settle: {}))
        }
        do {
            let (window, _) = main(.dictionary, dictionary: "")
            save("main-dictionary-empty-dark.png", snapshot(window, dark: true, settle: {}))
        }
        do {
            let (window, model) = main(.dictionary)
            save("main-dictionary-search-light.png", snapshot(window, dark: false, settle: { model.dictionary.query = "tens" }))
        }
        // Just removed a term: the Undo bar.
        for dark in [false, true] {
            let (window, model) = main(.dictionary)
            save("main-dictionary-removed-\(dark ? "dark" : "light").png", snapshot(window, dark: dark, settle: {
                model.dictionary.load()
                if let e = model.dictionary.entries.first(where: { $0.term == "Postgres" }) { model.dictionary.remove(e) }
            }))
        }
        do {
            // A term with many replacements wraps onto a second line; a long term is cut in the middle.
            let text = SampleDictionary.text + "\nKubernetes: cooper netties, cube or nettys, kuber nettys, coup bernetes, cube burnettes, Kubernetties\n"
                + "International Business Machines Corporation\n"
            let (window, model) = main(.dictionary, dictionary: text)
            save("main-dictionary-wrap-dark.png", snapshot(window, dark: true, settle: { model.dictionary.query = "ern" }))
        }
        do {
            // Amber, the lightest accent: Home's buttons and the sidebar icons must still read.
            let (window, model) = main(.home)
            save("main-home-amber-light.png", snapshot(window, dark: false, settle: {
                model.accent = Color(cgColor: PillAccent.amber.controlColor)
                prepareLibrary(model.library)
            }))
        }
        // Settings, as a tab.
        for dark in [false, true] {
            let (window, _) = main(.settings)
            save("main-settings-\(dark ? "dark" : "light").png", snapshot(window, dark: dark, settle: {}))
        }

        // The settings form on its own (each state of the setup rows).
        for (name, dark, advanced) in [("settings-light.png", false, false), ("settings-dark.png", true, false), ("settings-advanced-light.png", false, true)] {
            let view = SettingsView(settings: settings, inputs: inputs, loginItem: .fake(), showAdvanced: advanced)
                .environment(\.controlActiveState, .key)
            save(name, snapshot(Windows.panel(view, title: "Saylark Settings"), dark: dark, settle: {}))
        }

        // Settings: ready, then each way pasting can be blocked, shown inline.
        let activeDefaults = UserDefaults(suiteName: "saylark.render.\(UUID().uuidString)")!
        let active = AppSettings(defaults: activeDefaults)
        let blocked: [(String, ActiveReadiness, Bool, Bool)] = [
            ("settings-active-ready-light.png", ActiveReadiness(), false, false),
            ("settings-active-ready-dark.png", ActiveReadiness(), true, false),
            ("settings-active-needs-light.png", ActiveReadiness(accessibility: false, clipboard: .wouldAsk), false, false),
            ("settings-active-needs-dark.png", ActiveReadiness(accessibility: false, clipboard: .denied), true, false),
            ("settings-active-clash-light.png", ActiveReadiness(triggerClash: "Wispr Flow"), false, false),
            ("settings-active-advanced-light.png", ActiveReadiness(), false, true),
        ]
        for (name, readiness, dark, advanced) in blocked {
            let view = SettingsView(settings: active, inputs: inputs, loginItem: .fake(), setup: .preview(readiness), showAdvanced: advanced)
                .environment(\.controlActiveState, .key)
            save(name, snapshot(Windows.panel(view, title: "Saylark Settings"), dark: dark, settle: {}))
        }
        do {
            // Shortcut on Right Option and Return sends in every app (no list).
            let d = UserDefaults(suiteName: "saylark.render.\(UUID().uuidString)")!
            let custom = AppSettings(defaults: d)
            custom.triggerKey = .rightOption
            custom.sendOnReturn = .everywhere
            let view = SettingsView(settings: custom, inputs: inputs, loginItem: .fake(), setup: .preview(ActiveReadiness()))
                .environment(\.controlActiveState, .key)
            save("settings-active-return-everywhere-light.png", snapshot(Windows.panel(view, title: "Saylark Settings"), dark: false, settle: {}))
        }

        // Onboarding, each step (and the states a permission step can be in).
        let steps: [(String, OnboardingModel.Step, [Permission: PermissionStatus], String, Bool)] = [
            ("onboarding-1-welcome-light.png", .welcome, [:], "", false),
            ("onboarding-1-welcome-dark.png", .welcome, [:], "", true),
            ("onboarding-2-microphone.png", .microphone, [.microphone: .notDetermined], "", false),
            ("onboarding-2-microphone-granted.png", .microphone, [.microphone: .granted], "", false),
            ("onboarding-3-keyboard.png", .keyboard, [.inputMonitoring: .notDetermined], "", false),
            ("onboarding-3-keyboard-denied.png", .keyboard, [.inputMonitoring: .denied], "", false),
            ("onboarding-4-accessibility.png", .accessibility, [.accessibility: .notDetermined], "", false),
            ("onboarding-4-accessibility-granted.png", .accessibility, [.accessibility: .granted], "", false),
            ("onboarding-4-accessibility-denied-dark.png", .accessibility, [.accessibility: .denied], "", true),
            ("onboarding-4-try-it.png", .tryIt, [:], "", false),
            ("onboarding-4-try-it-words.png", .tryIt, [:], "Testing one two three. This is my first take with Saylark.", false),
            ("onboarding-4-try-it-dark.png", .tryIt, [:], "Testing one two three. This is my first take with Saylark.", true),
        ]
        for (name, step, states, text, dark) in steps {
            let perms = FakePermissions(states)
            let model = OnboardingModel(permissions: perms, step: step)
            model.practiceText = text
            let view = OnboardingView(model: model, accent: settings.accent).tint(accent).environment(\.controlActiveState, .key)
            save(name, snapshot(Windows.panel(view, title: "Welcome to Saylark", transparentTitle: true), dark: dark, settle: {}))
        }

        // The clipboard step: before macOS asks, allowed, and after an answer that was not Always Allow.
        let clipboardSteps: [(String, ActiveReadiness, Bool, Bool)] = [
            ("onboarding-5-clipboard.png", ActiveReadiness(clipboard: .wouldAsk), false, false),
            ("onboarding-5-clipboard-allowed.png", ActiveReadiness(clipboard: .allowed), false, false),
            ("onboarding-5-clipboard-settings.png", ActiveReadiness(clipboard: .wouldAsk), false, true),
            ("onboarding-5-clipboard-denied-dark.png", ActiveReadiness(clipboard: .denied), true, true),
        ]
        for (name, readiness, dark, asked) in clipboardSteps {
            let perms = FakePermissions()
            let model = OnboardingModel(permissions: perms, step: .clipboard, settings: active, setup: .preview(readiness, clipboardAsked: asked))
            let view = OnboardingView(model: model, accent: settings.accent).tint(accent).environment(\.controlActiveState, .key)
            save(name, snapshot(Windows.panel(view, title: "Welcome to Saylark", transparentTitle: true), dark: dark, settle: {}))
        }

        // The last step, with another dictation app on Fn, and plain.
        for (name, readiness, dark) in [("onboarding-6-try-it-clash.png", ActiveReadiness(triggerClash: "Wispr Flow"), false),
                                        ("onboarding-6-try-it-dark.png", ActiveReadiness(), true)] {
            let d = UserDefaults(suiteName: "saylark.render.\(UUID().uuidString)")!
            let chosen = AppSettings(defaults: d)
            let model = OnboardingModel(permissions: FakePermissions(), step: .tryIt, settings: chosen, setup: .preview(readiness))
            let view = OnboardingView(model: model, accent: settings.accent).tint(accent).environment(\.controlActiveState, .key)
            save(name, snapshot(Windows.panel(view, title: "Welcome to Saylark", transparentTitle: true), dark: dark, settle: {}))
        }

        // Onboarding while the engine loads or fails to start.
        let reopen = StartFailure(message: "macOS hasn't let Saylark see the Fn key yet. Reopening Saylark usually fixes it.", action: .reopen)
        let model = StartFailure(message: "Saylark couldn't load its speech model. Check your internet connection, then try again.", action: .tryAgain)
        let engineSteps: [(String, OnboardingModel.Step, EngineSupervisor.Phase, ModelState, Bool)] = [
            ("onboarding-2-microphone-downloading.png", .microphone, .starting, .downloading(progress: 0.42), false),
            ("onboarding-3-keyboard-compiling-dark.png", .keyboard, .starting, .compiling(progress: 0.6), true),
            ("onboarding-4-try-it-warming.png", .tryIt, .starting, .warming, false),
            ("onboarding-4-try-it-no-permission.png", .tryIt, .waitingForPermissions, .notLoaded, false),
            ("onboarding-4-try-it-reopen.png", .tryIt, .failed(reopen), .ready, false),
            ("onboarding-4-try-it-model-failed-dark.png", .tryIt, .failed(model), .failed("offline"), true),
        ]
        for (name, step, phase, modelState, dark) in engineSteps {
            let perms = FakePermissions([.microphone: .notDetermined, .inputMonitoring: .notDetermined])
            let supervisor = EngineSupervisor(engine: FakeEngine(), permissions: perms)
            supervisor.preview(phase: phase, model: modelState)
            let m = OnboardingModel(permissions: perms, step: step, supervisor: supervisor)
            let view = OnboardingView(model: m, accent: settings.accent).tint(accent).environment(\.controlActiveState, .key)
            save(name, snapshot(Windows.panel(view, title: "Welcome to Saylark", transparentTitle: true), dark: dark, settle: {}))
        }

        // Settings: a login item that needs approval in System Settings.
        do {
            let pending = LoginItem(status: { .needsApproval }, setEnabled: { _ in })
            let view = SettingsView(settings: settings, inputs: inputs, loginItem: pending).environment(\.controlActiveState, .key)
            save("settings-login-approval-light.png", snapshot(Windows.panel(view, title: "Saylark Settings"), dark: false, settle: {}))
        }

        // The menu bar menu, as the model builds it (a mock of the real NSMenu).
        do {
            let now = Date()
            let take = SampleTakes.history(now: now)
            var cancelled = take[0]
            cancelled.id = UUID(); cancelled.startedAt = now.addingTimeInterval(-90); cancelled.outcome = .cancelled
            let menus: [(String, MenuModel, Bool)] = [
                ("menu-light.png", MenuModel(recent: take, now: now), false),
                ("menu-recover-dark.png", MenuModel(recent: [cancelled] + take, now: now), true),
                ("menu-paused-dark.png", MenuModel(recent: take, now: now, pausedUntil: now.addingTimeInterval(3000)), true),
            ]
            for (name, model, dark) in menus {
                save(name, snapshot(Windows.panel(MenuPreview(model: model), title: "Menu bar menu"), dark: dark, settle: {}))
            }
        }

        save("menubar-glyphs.png", glyphSheet())
        if let icon = NSImage(contentsOfFile: "packaging/AppIcon.icns") {
            save("icon-sizes.png", iconSheet(icon))
        }
        print("rendered \(made.count) images to \(outDir.path)")
        return !made.isEmpty
    }

    private static func libraryModel() -> LibraryModel {
        LibraryModel(history: FakeHistory(SampleTakes.history()))
    }

    private static func prepareLibrary(_ model: LibraryModel) {
        let records = model.all
        guard records.count > 3 else { return }
        model.expanded = records[0].id
        model.player.open(records[0], url: nil)
        model.player.seek(to: records[0].duration * 0.42)
        model.hoverPreview = records[2].id
    }

    // MARK: Snapshots

    /// Lays a window out offscreen, lets SwiftUI settle (tasks, layout), applies `settle`, and draws
    /// the whole frame including the title bar and toolbar.
    static func snapshot(_ window: AppWindow, dark: Bool, settle: () -> Void) -> NSBitmapImageRep? {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.looksKey = true
        spin(0.4)
        settle()
        spin(0.4)
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        window.close()
        return rep
    }

    /// Runs the main run loop briefly so main-actor tasks and SwiftUI updates go through.
    static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Sheets

    private static func glyphSheet() -> NSBitmapImageRep? {
        let states = MenuBarGlyph.State.allCases
        let cell = CGSize(width: 150, height: 64)
        let rows = [false, true]
        let size = CGSize(width: cell.width * CGFloat(states.count), height: cell.height * CGFloat(rows.count))
        return drawSheet(size: size) { _ in
            for (row, dark) in rows.enumerated() {
                let y = size.height - CGFloat(row + 1) * cell.height
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell.height).fill()
                for (i, s) in states.enumerated() {
                    let img = MenuBarGlyph.image(s)
                    let tinted = NSImage(size: img.size, flipped: false) { r in
                        img.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    let x = CGFloat(i) * cell.width
                    tinted.draw(in: NSRect(x: x + (cell.width - 40) / 2 - 20, y: y + 22, width: 40, height: 36))
                    tinted.draw(in: NSRect(x: x + 8, y: y + 6, width: img.size.width, height: img.size.height))
                    let label = NSAttributedString(string: s.rawValue, attributes: [
                        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.5)])
                    label.draw(at: NSPoint(x: x + 34, y: y + 8))
                }
            }
        }
    }

    private static func iconSheet(_ icon: NSImage) -> NSBitmapImageRep? {
        let sizes: [CGFloat] = [256, 128, 64, 32, 16]
        let size = CGSize(width: 640, height: 600)
        return drawSheet(size: size) { _ in
            for (row, dark) in [false, true].enumerated() {
                let y = size.height - CGFloat(row + 1) * 300
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: 300).fill()
                var x: CGFloat = 20
                for s in sizes {
                    icon.draw(in: NSRect(x: x, y: y + (300 - s) / 2, width: s, height: s))
                    x += s + 20
                }
            }
        }
    }

    private static func drawSheet(size: CGSize, scale: CGFloat = 2, _ draw: (CGSize) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}


/// A drawing of the menu bar menu from its model, for review renders. The real menu is an NSMenu.
struct MenuPreview: View {
    let model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .separator:
                    Divider().padding(.vertical, 4)
                case .item(let item):
                    row(item)
                case .submenu(let title, let items):
                    Text(title).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 2)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(item.checked ? 1 : 0)
                            Text(item.title).font(.system(size: 13))
                        }
                        .padding(.leading, 26).padding(.vertical, 1)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 280, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ item: MenuModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title).font(.system(size: 13)).foregroundStyle(item.enabled ? .primary : .secondary)
            if let sub = item.subtitle { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}
