import AppKit
import Observation
import SaylarkCore
import SwiftUI

/// The menu bar app: owns the engine, the pill, the menu and two windows (the Saylark window with
/// Home, Dictionary and Settings, and first run). Engine events arrive on one stream and fan out
/// from here. While the Saylark window is open the app is a regular app (Dock icon, ⌘-Tab); when
/// it closes, Saylark goes back to the menu bar only.
@MainActor public final class AppController: NSObject, NSMenuDelegate, NSApplicationDelegate, NSWindowDelegate {
    public let engine: any DictationEngine
    public let settings: AppSettings
    let permissions: any PermissionsProviding
    let loginItem: LoginItem
    /// Shows the "Play a fake take" items in the menu.
    let isFake: Bool

    let pill: LivePill
    /// What pasting still needs (accessibility, clipboard, a clashing app), for Settings, the menu
    /// bar glyph and onboarding.
    public let setup: ActiveSetup
    /// Starts the engine as soon as permissions exist and reports model loading and failures.
    public let supervisor: EngineSupervisor
    let inputList = InputList.system()
    /// The user's dictionary file (the Dictionary tab edits it; the engine watches it).
    let dictionaryURL: URL
    /// Switches between a regular app and menu bar only. Replaced in tests.
    var setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }
    /// Brings the Saylark window forward. Replaced in tests, so they never take focus.
    var showWindow: @MainActor (NSWindow) -> Void = { Windows.show($0) }
    /// Reopens the app (used after Input Monitoring is granted to a running app). Replaced in tests.
    var relaunch: @MainActor () -> Void = { AppController.relaunchApp() }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var main: (window: NSWindow, model: MainModel)?
    private var onboarding: (window: NSWindow, model: OnboardingModel)?
    /// The newest takes seen this session (and loaded at launch), for the menu.
    private var recent: [DictationRecord] = []
    private var pausedUntil: Date?
    private var resumeTask: Task<Void, Never>?
    private let sounds = SoundPlayer()
    private var shownGlyph: MenuBarGlyph.State?
    private var shownFailure: StartFailure?
    private var deviceWatch: DeviceObservation?

    public init(engine: any DictationEngine, settings: AppSettings, permissions: any PermissionsProviding,
                loginItem: LoginItem = .system, isFake: Bool = false, dictionaryURL: URL = DictionaryFile.defaultURL) {
        self.engine = engine
        self.dictionaryURL = dictionaryURL
        self.settings = settings
        self.permissions = permissions
        self.loginItem = loginItem
        self.isFake = isFake
        pill = LivePill(theme: settings.pillTheme)
        supervisor = EngineSupervisor(engine: engine, permissions: permissions)
        setup = ActiveSetup(engine: engine, permissions: permissions, settings: settings)
        super.init()
        pill.micName = "microphone"
        pill.onFinish = { [weak self] in self?.engine.finishTake() }
        pill.onErrorAction = { [weak self] in self?.recover(from: $0) }
        pill.onCardCopy = { [weak self] in self?.engine.cardCopy() }
        pill.onCardPasteWhenField = { [weak self] in self?.engine.cardPasteWhenField() }
        pill.onCardDismiss = { [weak self] in self?.engine.cardDismiss() }
        pill.onCardReasonAction = { [weak self] in self?.fix(card: $0) }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateGlyph()
        applyTheme()
        observeSettings()
        observeSupervisor()
        observeReduceMotion()
        deviceWatch = AudioInputs.observe { [weak self] in self?.refreshMicName() }
        refreshMicName()
    }

    /// Starts listening to the engine. The engine starts now if every permission exists, so the
    /// "Try it" step and the first Fn press work; first run shows onboarding, and a relaunch with a
    /// missing permission shows it without taking focus.
    public func launch() {
        NSApp.delegate = self
        AppMenu.install(target: self, openMain: #selector(openSaylark), openSettings: #selector(openSettings), find: #selector(find))
        Task { for await event in engine.events { handle(event) } }
        Task { [weak self] in
            guard let self else { return }
            let seen = (try? await engine.history.recent(limit: 20, before: nil)) ?? []
            for r in seen { remember(r) }
        }
        supervisor.follow()
        supervisor.startIfPossible()
        inputList.refresh()
        if !settings.onboarded {
            showOnboarding(activate: true)
        } else if !supervisor.missingPermissions.isEmpty {
            showOnboarding(activate: false)
        }
    }

    // MARK: Application delegate

    /// Double-clicking the app's icon while it runs (the status item can hide behind the notch), or
    /// clicking it in the Dock.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSaylark()
        return false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Events

    private func handle(_ event: DictationEvent) {
        if let record = pill.handle(event) {
            remember(record)
            main?.model.library.upsert(record)
        }
        if case .pill(let e, _) = event {
            updateGlyph()
            playCue(for: e)
        }
    }

    private func remember(_ record: DictationRecord) {
        recent.removeAll { $0.id == record.id }
        recent.append(record)
        recent.sort { $0.startedAt > $1.startedAt }
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
    }

    private func playCue(for event: PillEvent) {
        guard settings.sounds else { return }
        switch event {
        case .listen: sounds.play(.start)
        case .finish, .cancel: sounds.play(.stop)
        default: break
        }
    }

    private func recover(from error: PillError) {
        switch error {
        case .microphoneAccessOff: permissions.openSystemSettings(.microphone)
        case .accessibilityOff: permissions.openSystemSettings(.accessibility)
        // The built-in mic when there is one, otherwise Automatic.
        case .microphoneMissing: settings.microphoneUID = inputList.builtIn?.uid
        case .transcriptionFailed, .modelNotReady: break
        case .clipboardAccessOff: fix(card: .clipboardNotAllowed)
        case .pasteFailed: openMain(.home)
        }
    }

    /// The button above a card's actions, or on the clipboard notice.
    private func fix(card reason: CardReason) {
        switch reason {
        case .accessibilityOff:
            Task { await permissions.request(.accessibility); setup.refresh(); updateGlyph() }
        case .clipboardNotAllowed:
            Task {
                let state = await setup.requestClipboard()
                if state == .denied { setup.openClipboardSettings() }
                setup.refresh()
                updateGlyph()
            }
        }
    }

    // MARK: Settings and system state → pill

    private func observeSettings() {
        withObservationTracking {
            _ = settings.pillTheme
            _ = settings.triggerKey
            _ = settings.microphoneUID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.setup.refresh()
                self?.applyTheme()
                self?.refreshMicName()
                self?.observeSettings()
            }
        }
    }

    /// The engine's phase and the model's progress decide whether Fn can work, so they decide whether
    /// the passive Fn watcher runs, and a failed start surfaces once.
    private func observeSupervisor() {
        withObservationTracking {
            _ = supervisor.phase
            _ = supervisor.model
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.supervisorChanged()
                self?.observeSupervisor()
            }
        }
    }

    private func supervisorChanged() {
        guard case .failed(let failure) = supervisor.phase else { shownFailure = nil; return }
        if failure != shownFailure {
            shownFailure = failure
            // The window explains the failure; it must not take focus from whatever is being typed.
            showOnboarding(activate: false)
        }
    }

    /// Reduce Motion is read live: the system tells us when it changes.
    private func observeReduceMotion() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    private func applyTheme() {
        var theme = settings.pillTheme
        theme.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pill.theme = theme
        main?.model.library.triggerName = settings.triggerKey.title
        // The window is kept between openings, so a new accent chosen in Settings reaches it here.
        main?.model.accent = accent
        updateGlyph()
    }

    /// The microphone the pill names in "Not hearing you": the one Saylark will really use.
    private func refreshMicName() {
        let uid = settings.microphoneUID
        Task { [weak self] in
            let name = await Task.detached(priority: .utility) { AudioInputs.current(pinnedUID: uid)?.name }.value
            self?.pill.micName = name.map(AudioInputs.pillName) ?? "microphone"
        }
    }

    // MARK: Menu bar

    private func updateGlyph() {
        var problem = false
        switch supervisor.phase {
        case .failed, .waitingForPermissions: problem = true
        default: problem = supervisor.model.isFailed
        }
        if !setup.readiness.canPaste { problem = true }
        let state = MenuModel.glyph(listening: pill.state.phase == .listening, paused: pausedUntil != nil, problem: problem)
        // Assign only on a real change: live words send many pill events per second.
        guard state != shownGlyph else { return }
        shownGlyph = state
        statusItem.button?.image = MenuBarGlyph.image(state)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        setup.refresh()
        updateGlyph()
        addEngineStatus(to: menu)
        let model = MenuModel(recent: recent, pausedUntil: pausedUntil)
        for entry in model.entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let spec):
                menu.addItem(menuItem(spec))
            case .submenu(let title, let items):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: title)
                for spec in items { sub.addItem(menuItem(spec)) }
                parent.submenu = sub
                menu.addItem(parent)
            }
        }
        if isFake {
            // Before the last separator, Settings and Quit.
            let at = max(0, menu.items.count - 3)
            menu.insertItem(.separator(), at: at)
            menu.insertItem(item("Play a Fake Take", #selector(fakeTake)), at: at + 1)
            menu.insertItem(item("Play a Fake Hands-free Take", #selector(fakeHandsFree)), at: at + 2)
            menu.insertItem(item("Play a Fake Take, No Text Field", #selector(fakeNoField)), at: at + 3)
        }
    }

    private func menuItem(_ spec: MenuModel.Item) -> NSMenuItem {
        let key: String
        switch spec.action {
        case .openSaylark: key = "o"
        case .openSettings: key = ","
        case .quit: key = "q"
        default: key = ""
        }
        let i = NSMenuItem(title: spec.title, action: spec.action == nil ? nil : #selector(menuAction(_:)), keyEquivalent: key)
        i.target = self
        i.isEnabled = spec.enabled
        i.state = spec.checked ? .on : .off
        if let subtitle = spec.subtitle { i.subtitle = subtitle }
        if let action = spec.action { i.representedObject = MenuActionBox(action) }
        if spec.action == .copyLast, let last = MenuModel.lastTranscript(in: recent) { i.toolTip = last.cleanText }
        return i
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? MenuActionBox)?.action else { return }
        switch action {
        case .copyLast: copyLast()
        case .pasteLast:
            if let last = MenuModel.lastTranscript(in: recent) { Task { await engine.paste(last.id) } }
        case .recover(let id):
            if let take = recent.first(where: { $0.id == id }) {
                Task { await TakeActions.pasteOrRecover(take, engine: engine) }
            }
        case .openSaylark: openSaylark()
        case .pause: pause()
        case .resume: resume()
        case .openSettings: openSettings()
        case .quit: quit()
        }
    }

    /// The first menu row says what Saylark is doing when it isn't ready: loading the model with
    /// progress, waiting for permission, or why it didn't start (with the one action that helps).
    private func addEngineStatus(to menu: NSMenu) {
        switch supervisor.phase {
        case .running where supervisor.model == .ready, .paused:
            return
        case .failed(let failure):
            let row = NSMenuItem(title: "Saylark didn't start", action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.toolTip = failure.message
            menu.addItem(row)
            menu.addItem(item(failure.actionTitle, #selector(runFailureAction)))
        case .waitingForPermissions:
            let row = NSMenuItem(title: "Needs permission to start", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            menu.addItem(item("Finish Setup…", #selector(finishSetup)))
        case .starting, .running:
            let row = NSMenuItem(title: supervisor.statusLine ?? "Starting", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Copies the last transcript. Runs only from the user's click on the menu item.
    @objc private func copyLast() {
        guard let record = MenuModel.lastTranscript(in: recent) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.cleanText, forType: .string)
    }

    @objc private func pause() {
        supervisor.pause()
        pausedUntil = Date().addingTimeInterval(3600)
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3600))
            guard !Task.isCancelled else { return }
            self?.resume()
        }
        updateGlyph()
    }

    @objc private func resume() {
        resumeTask?.cancel()
        pausedUntil = nil
        supervisor.resume()
        updateGlyph()
    }

    @objc private func runFailureAction() {
        guard let failure = supervisor.failure else { return }
        switch failure.action {
        case .tryAgain: supervisor.retry()
        case .reopen: relaunch()
        }
    }

    @objc private func finishSetup() { showOnboarding(activate: true) }

    @objc private func fakeTake() { (engine as? FakeEngine)?.playTake() }
    @objc private func fakeHandsFree() { (engine as? FakeEngine)?.playTake(handsFree: true) }
    @objc private func fakeNoField() { (engine as? FakeEngine)?.playTake(ending: .noField) }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Starts a fresh copy of the app a moment after this one quits.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", url.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Windows

    /// The accent for window controls: the deeper shade of the pill's colour, readable on white.
    private var accent: Color { Color(cgColor: settings.accent.controlColor) }

    /// Opens the Saylark window on the tab it last showed (Home the first time).
    @objc public func openSaylark() { openMain(nil) }

    @objc public func openSettings() { openMain(.settings) }

    /// Edit > Find (⌘F): the search field of the tab showing.
    @objc public func find() { main?.model.find() }

    /// Shows the Saylark window, on `tab` when given. The app becomes a regular app while it is open.
    public func openMain(_ tab: MainTab?) {
        if main == nil {
            let library = LibraryModel(history: engine.history)
            library.engine = engine
            library.triggerName = settings.triggerKey.title
            let model = MainModel(library: library, dictionary: DictionaryModel(url: dictionaryURL), accent: accent)
            let view = MainView(model: model) {
                SettingsView(settings: settings, inputs: inputList, loginItem: loginItem, setup: setup)
            }
            let window = Windows.main(view)
            window.delegate = self
            main = (window, model)
        }
        if let tab { main?.model.tab = tab }
        // Closing the window stops the file watch; pick up edits made meanwhile and watch again.
        main?.model.dictionary.load()
        main?.model.dictionary.watch()
        inputList.refresh()
        setActivationPolicy(.regular)
        showWindow(main!.window)
    }

    /// Back to menu bar only once the Saylark window closes. The window and its state are kept, so
    /// it opens again where it was.
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === main?.window else { return }
        main?.model.dictionary.stopWatching()
        main?.model.library.player.stop()
        setActivationPolicy(.accessory)
    }

    /// `activate: false` puts the window up without taking focus: for a relaunch or a failed start,
    /// when the user is probably typing somewhere else.
    public func showOnboarding(activate: Bool = true) {
        if onboarding == nil {
            let step = OnboardingModel.firstStep(onboarded: settings.onboarded, missing: supervisor.missingPermissions,
                                                 startFailed: supervisor.failure != nil)
            let model = OnboardingModel(permissions: permissions, step: step, supervisor: supervisor, settings: settings, setup: setup)
            model.onRefresh = { [weak self] in self?.supervisor.startIfPossible() }
            model.onFinish = { [weak self] in self?.finishOnboarding() }
            model.onReopen = { [weak self] in self?.relaunch() }
            let window = Windows.panel(OnboardingView(model: model, accent: settings.accent).tint(accent), title: "Welcome to Saylark",
                                       transparentTitle: true)
            onboarding = (window, model)
        }
        Windows.show(onboarding!.window, activate: activate)
    }

    private func finishOnboarding() {
        settings.onboarded = true
        onboarding?.window.close()
        onboarding = nil
        supervisor.startIfPossible()
    }
}


/// Carries a menu action through `NSMenuItem.representedObject`.
private final class MenuActionBox: NSObject {
    let action: MenuModel.Action
    init(_ action: MenuModel.Action) { self.action = action }
}

/// The app's windows. `looksKey` draws a window as the active one even when it isn't, so offscreen
/// review renders show controls in their real, active colours.
final class AppWindow: NSWindow {
    var looksKey = false
    /// Keeps a helper (toolbar delegate) alive as long as the window.
    var helper: AnyObject?
    override var isKeyWindow: Bool { looksKey || super.isKeyWindow }
    override var isMainWindow: Bool { looksKey || super.isMainWindow }
}

/// Window construction shared by the app and the review renderer, so renders show the real chrome.
@MainActor enum Windows {
    /// The Saylark window: sidebar and page, the title bar blended into the content.
    static func main<V: View>(_ view: V, remembersFrame: Bool = true) -> AppWindow {
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = AppWindow(contentRect: CGRect(x: 0, y: 0, width: 940, height: 640),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "Saylark"
        window.toolbarStyle = .unified
        window.setContentSize(CGSize(width: 940, height: 640))
        window.contentMinSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        // Centre only the first time: a saved frame (where the user left the window) wins. Renders
        // pass remembersFrame: false so they never write the user's saved frame.
        let name = "SaylarkMain"
        let hasSavedFrame = remembersFrame && UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") != nil
        if remembersFrame { window.setFrameAutosaveName(name) }
        if !hasSavedFrame { window.center() }
        return window
    }

    static func panel<V: View>(_ view: V, title: String, transparentTitle: Bool = false) -> AppWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = AppWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = title
        if transparentTitle {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Brings a window forward. Windows the user asked for take focus; `activate: false` shows it
    /// without activating the app or taking key, so it never steals typing from another app.
    static func show(_ window: NSWindow, activate: Bool = true) {
        if activate {
            // Opened from the menu bar item, Saylark is not the active app, and macOS 14+'s
            // cooperative `activate()` may decline, leaving the window behind the app in front.
            // The user asked for this window, so take focus outright, and again on the next turn
            // of the run loop, after a just-changed activation policy has settled.
            let bringForward = {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            bringForward()
            DispatchQueue.main.async { bringForward() }
        } else {
            window.orderFrontRegardless()
        }
    }
}
