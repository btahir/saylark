import AppKit
import QuartzCore
import SaylarkCore

/// The real pill on screen: engine events go into a `LivePillSession`, the panel reads it each
/// display frame. The panel is created once at launch and stays non-activating.
@MainActor public final class LivePill {
    public let panel: PillPanel
    private var session = LivePillSession()
    private let t0 = CACurrentMediaTime()
    /// Stop button and Esc go back to the engine.
    public var onFinish: (() -> Void)?
    public var onErrorAction: ((PillError) -> Void)?
    /// Card buttons. They run the engine's card methods; the pill updates itself at once.
    public var onCardCopy: (() -> Void)?
    public var onCardPasteWhenField: (() -> Void)?
    /// Dismiss, Cancel while waiting, or the card timing out: the engine stops holding the text.
    public var onCardDismiss: (() -> Void)?
    /// The button that fixes why the card could not paste.
    public var onCardReasonAction: ((CardReason) -> Void)?
    private var lastPhase: PillPhase = .hidden
    private var closedByUser = false
    /// Where the pill goes when it appears. The app uses the screen with the pointer; tests replace it.
    var screenForPlacement: () -> NSScreen? = {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    public init(theme: PillTheme) {
        panel = PillPanel(theme: theme)
        panel.frameSource = { [weak self] in
            guard let self else { return (PillState(), 0, nil) }
            let t = self.now
            let f = self.session.frame(at: t)
            self.noteCardClosing(f.state.phase)
            return (f.state, t, f.rms)
        }
        panel.onHit = { [weak self] hit in self?.handle(hit) }
        panel.onHover = { [weak self] inside in
            guard let self else { return }
            self.session.handle(.pill(.hover(inside)), at: self.now)
        }
        // A display was plugged in, unplugged or rearranged while the pill is up: put it back on a real screen.
        // The pill lives as long as the app, so the observer is never removed.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel.panel.isVisible == true { self?.place() } }
        }
    }

    private var now: Double { CACurrentMediaTime() - t0 }

    public var theme: PillTheme {
        get { panel.view.theme }
        set { panel.view.theme = newValue }
    }

    public var state: PillState { session.state }

    /// The pill's name for the mic in "Not hearing you. Check the …".
    public var micName: String {
        get { panel.view.config.micName }
        set { panel.view.config.micName = newValue }
    }

    /// The pill is placed when it goes from hidden to shown, or when its panel is not on screen.
    nonisolated static func needsPlacement(wasVisible: Bool, panelOnScreen: Bool) -> Bool {
        !wasVisible || !panelOnScreen
    }

    private func place() {
        guard let screen = screenForPlacement() else { return }
        panel.place(on: screen)
    }

    /// The card or the waiting notice went away without a button (it timed out): tell the engine, so
    /// it stops waiting for a field.
    private func noteCardClosing(_ phase: PillPhase) {
        defer { lastPhase = phase }
        switch lastPhase {
        case .card, .waitingForField:
            if phase == .hidden {
                if closedByUser { closedByUser = false } else { onCardDismiss?() }
            }
        default: break
        }
    }

    /// Applies an engine event. Returns the record for `.saved`.
    @discardableResult
    public func handle(_ event: DictationEvent) -> DictationRecord? {
        apply(event)
    }

    @discardableResult
    private func apply(_ event: DictationEvent) -> DictationRecord? {
        let wasVisible = session.state.isVisible
        let record = session.handle(event, at: now)
        if case .pill = event, session.state.isVisible {
            // Place whenever the pill goes from hidden to shown, whatever event did it. An error can
            // be the first event of a take (mic access off) with no .listen before it, and used to
            // appear at the panel's initial position in the corner of the main display.
            if Self.needsPlacement(wasVisible: wasVisible, panelOnScreen: panel.panel.isVisible) { place() }
            panel.wake()
        }
        return record
    }

    private func handle(_ hit: PillHit) {
        switch hit {
        case .stop:
            onFinish?()
        case .pasteWhenFocused:
            onCardPasteWhenField?()
            session.handle(.pill(.pasteWhenFocused), at: now)
        case .copy:
            onCardCopy?()
            session.handle(.pill(.copied), at: now)
        case .dismiss:
            switch session.state.phase {
            case .card, .waitingForField: closedByUser = true; onCardDismiss?()
            default: break
            }
            session.handle(.pill(.dismiss), at: now)
        case .reasonAction:
            if let reason = session.state.cardReason { onCardReasonAction?(reason) }
        case .errorAction:
            if case .error(let e) = session.state.phase { onErrorAction?(e) }
            session.handle(.pill(.dismiss), at: now)
        }
        panel.wake()
    }
}
