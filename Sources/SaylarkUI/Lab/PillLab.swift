import AppKit
import QuartzCore
import SaylarkCore

/// Drives a `PillMachine` from lab buttons with a recorded voice envelope instead of the mic.
@MainActor final class LabSession {
    var machine = PillMachine()
    var envelopes: [String: VoiceEnvelope]
    var clipID: String
    var signalMuted = false
    private var voiceStart = 0.0
    private var pendingWords: [TimedPillEvent] = []
    let t0 = CACurrentMediaTime()

    init(envelopes: [String: VoiceEnvelope]) {
        self.envelopes = envelopes
        clipID = envelopes.keys.sorted().first ?? ""
    }

    var now: Double { CACurrentMediaTime() - t0 }

    func send(_ event: PillEvent, at time: Double? = nil) {
        let t = time ?? now
        if event == .listen {
            voiceStart = t
            pendingWords = envelopes[clipID].map { PillScenarios.wordEvents($0, start: t) } ?? []
        }
        machine.handle(event, at: t)
    }

    /// State, time and RMS for one frame; also feeds scheduled live words and the no-signal check.
    func frame(at time: Double? = nil) -> (state: PillState, time: Double, rms: Float?) {
        let t = time ?? now
        while let w = pendingWords.first, w.time <= t {
            machine.handle(w.event, at: w.time)
            pendingWords.removeFirst()
        }
        var rms: Float?
        if machine.state.phase == .listening {
            if signalMuted {
                rms = 0
            } else if let clip = envelopes[clipID], clip.duration > 0 {
                // Loop the clip, with room tone in between.
                let local = (t - voiceStart).truncatingRemainder(dividingBy: clip.duration + 0.6)
                rms = max(clip.rms(at: local), 0.0006)
            } else {
                rms = 0.0006
            }
        }
        machine.tick(at: t, peakDB: rms.map { ($0 * 2).dBFS })
        return (machine.state, t, rms)
    }
}

/// `SaylarkApp --pill-lab`: a window where every pill state can be triggered by a button, over the
/// same backdrops as the renders. Hold Space in the window to talk (local key events only). Nothing
/// here installs event taps or monitors, opens the mic, or touches the clipboard.
@MainActor public enum PillLab {
    public static func run(envelopeDir: URL, selfTest: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(selfTest ? .prohibited : .regular)
        let envelopes = EnvelopeStore.load(from: envelopeDir)
        let lab = PillLabController(envelopes: envelopes)
        if selfTest {
            exit(lab.selfTest() ? 0 : 1)
        }
        lab.window.center()
        lab.window.makeKeyAndOrderFront(nil)
        app.activate()
        app.run()
    }
}

@MainActor final class PillLabController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let session: LabSession
    private let stage = LabStageView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
    private var pill: PillView
    private var panel: PillPanel?
    private var theme = PillTheme()
    private var backdrop = Backdrop.chatLight
    private let costLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private var link: CADisplayLink?
    private let linkTarget = DisplayLinkTarget()
    private var lastTimestamp: CFTimeInterval = 0
    private var costs: [Double] = []
    private var actions: [String: () -> Void] = [:]

    init(envelopes: [String: VoiceEnvelope]) {
        session = LabSession(envelopes: envelopes)
        pill = PillView(theme: theme, scale: NSScreen.main?.backingScaleFactor ?? 2)
        window = LabWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 540),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pill Lab"
        window.isReleasedWhenClosed = false
        window.delegate = self
        (window as? LabWindow)?.onSpace = { [weak self] down in
            guard let self else { return }
            if down { self.session.send(.listen) } else { self.session.send(.finish(.inserted)) }
            self.wake()
        }
        build()
        linkTarget.onFrame = { [weak self] l in self?.tick(l) }
    }

    // MARK: Layout

    private func build() {
        let root = NSView(frame: window.contentLayoutRect)
        stage.frame = CGRect(x: 20, y: 20, width: 800, height: 500)
        root.addSubview(stage)
        stage.onClick = { [weak self] p in
            guard let self, let hit = self.pill.hit(p) else { return }
            self.handle(hit)
        }
        stage.onHover = { [weak self] inside in self?.session.send(.hover(inside)) }
        stage.isOverPill = { [weak self] p in self?.pill.pillFrame.contains(p) ?? false }
        installPill()

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.frame = CGRect(x: 836, y: 20, width: 210, height: 500)

        func section(_ title: String) {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            column.addArrangedSubview(l)
        }
        func button(_ title: String, _ action: @escaping () -> Void) {
            actions[title] = action
            let b = NSButton(title: title, target: self, action: #selector(press(_:)))
            b.bezelStyle = .push
            b.controlSize = .small
            column.addArrangedSubview(b)
        }
        section("Take (or hold Space)")
        button("Fn down") { self.session.send(.listen) }
        button("Double-tap: hands-free") { self.session.send(.listen); self.session.send(.lockHandsFree) }
        button("Release: text lands") { self.session.send(.finish(.inserted)) }
        button("Release: no text field") {
            let text = self.session.envelopes[self.session.clipID]?.text ?? "Text that had nowhere to go."
            self.session.send(.finish(.noTextFieldCopied(text)))
        }
        button("Release: no text field, copy off") {
            let text = self.session.envelopes[self.session.clipID]?.text ?? "Text that had nowhere to go."
            self.session.send(.finish(.noTextField(text)))
        }
        button("Esc") { self.session.send(.cancel) }
        button("Release, then Fn again") {
            self.session.send(.finish(.inserted))
            let again = self.session.now + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.session.send(.listen, at: again) }
        }
        section("Card and notices")
        button("Paste when I click a field") { self.session.send(.pasteWhenFocused) }
        button("A field gets focus") { self.session.send(.fieldFocused) }
        button("Dismiss") { self.session.send(.dismiss) }
        button("Card: Copy") { self.session.send(.copied) }
        button("Card: accessibility off") {
            self.session.send(.finish(.cannotPaste("Text that could not be pasted.", reason: .accessibilityOff)))
        }
        button("Card: clipboard off") {
            self.session.send(.finish(.cannotPaste("Text that could not be pasted.", reason: .clipboardNotAllowed)))
        }
        button("Error: mic access off") { self.session.send(.fail(.microphoneAccessOff)) }
        button("Error: clipboard access off") { self.session.send(.fail(.clipboardAccessOff)) }
        button("Error: paste failed") { self.session.send(.fail(.pasteFailed)) }
        button("Notice: model loading") { self.session.send(.fail(.modelNotReady(message: "Downloading the speech model, 42%."))) }

        section("Options")
        column.addArrangedSubview(popup(session.envelopes.keys.sorted().map { id in
            let d = session.envelopes[id]!.duration
            return (String(format: "Voice %@ (%.1f s)", id, d), id)
        }) { self.session.clipID = $0 })
        column.addArrangedSubview(popup(VoiceVisualKind.allCases.map { ("Visual: \($0.rawValue)", $0.rawValue) }) {
            self.theme.visual = VoiceVisualKind(rawValue: $0)!; self.applyTheme()
        })
        column.addArrangedSubview(popup(PillAccent.allCases.map { ("Accent: \($0.rawValue)", $0.rawValue) }) {
            self.theme.accent = PillAccent(rawValue: $0)!; self.applyTheme()
        })
        column.addArrangedSubview(popup(Backdrop.allCases.map { ("Backdrop: \($0.rawValue)", $0.rawValue) }) {
            self.backdrop = Backdrop(rawValue: $0)!; self.installPill()
        })
        column.addArrangedSubview(check("Live words") { self.theme.liveWords = $0; self.applyTheme() })
        column.addArrangedSubview(check("Reduce Motion") { self.theme.reduceMotion = $0; self.applyTheme() })
        column.addArrangedSubview(check("Mute the voice (no signal)") { self.session.signalMuted = $0 })
        column.addArrangedSubview(check("Also show the real panel") { on in
            if on { self.makePanel() } else { self.panel?.panel.orderOut(nil); self.panel = nil }
        })
        stateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        costLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        column.addArrangedSubview(stateLabel)
        column.addArrangedSubview(costLabel)
        root.addSubview(column)
        window.contentView = root
    }

    private var popupHandlers: [ObjectIdentifier: (String) -> Void] = [:]
    private var checkHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]

    private func popup(_ items: [(String, String)], _ handler: @escaping (String) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        for (title, value) in items {
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = value
        }
        p.target = self
        p.action = #selector(popupChanged(_:))
        popupHandlers[ObjectIdentifier(p)] = handler
        return p
    }

    private func check(_ title: String, _ handler: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
        b.controlSize = .small
        checkHandlers[ObjectIdentifier(b)] = handler
        return b
    }

    @objc private func press(_ sender: NSButton) { trigger(sender.title) }
    @objc private func popupChanged(_ sender: NSPopUpButton) {
        if let v = sender.selectedItem?.representedObject as? String { popupHandlers[ObjectIdentifier(sender)]?(v) }
    }
    @objc private func checkChanged(_ sender: NSButton) { checkHandlers[ObjectIdentifier(sender)]?(sender.state == .on) }

    /// Runs a button's action by title (also used by the self-test).
    func trigger(_ title: String) {
        actions[title]?()
        wake()
    }

    private func handle(_ hit: PillHit) {
        switch hit {
        case .stop: session.send(.finish(.inserted))
        case .pasteWhenFocused: session.send(.pasteWhenFocused)
        case .copy: session.send(.copied)
        case .dismiss, .errorAction, .reasonAction: session.send(.dismiss)
        }
        wake()
    }

    private func installPill() {
        pill.layer.removeFromSuperlayer()
        pill = PillView(theme: theme, scale: window.backingScaleFactor)
        stage.setBackdrop(backdrop.image(size: stage.bounds.size, scale: window.backingScaleFactor))
        pill.layer.position = CGPoint(x: (stage.bounds.width - PillView.canvasSize.width) / 2, y: 0)
        stage.layer?.addSublayer(pill.layer)
        stage.pillOrigin = pill.layer.position
        wake()
    }

    private func applyTheme() {
        pill.theme = theme
        panel?.view.theme = theme
        wake()
    }

    private func makePanel() {
        let p = PillPanel(theme: theme)
        if let screen = NSScreen.main { p.place(on: screen) }
        p.frameSource = { [weak self] in self?.session.frame() ?? (PillState(), 0, nil) }
        p.onHit = { [weak self] hit in self?.handle(hit) }
        p.onHover = { [weak self] inside in self?.session.send(.hover(inside)) }
        panel = p
        wake()
    }

    // MARK: Frames

    private func wake() {
        if session.machine.state.isVisible { panel?.wake() }
        guard link == nil, window.isVisible else { return }
        let l = stage.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
    }

    private func tick(_ l: CADisplayLink) {
        let dt = lastTimestamp == 0 ? l.duration : l.targetTimestamp - lastTimestamp
        lastTimestamp = l.targetTimestamp
        step(dt: min(max(dt, 1.0 / 240), 1.0 / 30))
        if pill.isIdle, panel?.view.isIdle ?? true, !session.machine.state.isVisible {
            l.invalidate()
            link = nil
        }
    }

    private func step(dt: Double, at time: Double? = nil) {
        let f = session.frame(at: time)
        let start = DispatchTime.now().uptimeNanoseconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.update(state: f.state, time: f.time, rms: f.rms, dt: dt)
        CATransaction.commit()
        costs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        if costs.count > 600 { costs.removeFirst(costs.count - 600) }
        if costs.count % 30 == 0 { costLabel.stringValue = "frame " + PillRenderCommand.summary(costs) }
        stateLabel.stringValue = "\(f.state.phase.name)  \(f.state.mode == .handsFree ? "hands-free" : "hold")\(f.state.noSignal ? "  no signal" : "")"
    }

    func windowWillClose(_ notification: Notification) {
        link?.invalidate()
        NSApp.terminate(nil)
    }

    // MARK: Self-test

    /// Presses every button in order and steps frames by hand, checking the phase after each.
    /// Runs without showing a window. Returns true when every step lands in the expected phase.
    func selfTest() -> Bool {
        var t = 0.0
        var ok = true
        func run(_ title: String, frames: Int = 30, expect: String) {
            actions[title]?()
            for _ in 0..<frames { t += 1.0 / 120; step(dt: 1.0 / 120, at: session.now) }
            let got = session.machine.state.phase.name
            print("\(title.padding(toLength: 28, withPad: " ", startingAt: 0)) -> \(got) \(got == expect ? "ok" : "EXPECTED \(expect)")")
            if got != expect { ok = false }
        }
        run("Fn down", expect: "listening")
        run("Release: text lands", expect: "done")
        run("Double-tap: hands-free", expect: "listening")
        run("Release: no text field", expect: "card")
        run("Paste when I click a field", expect: "waiting")
        run("A field gets focus", expect: "done")
        run("Fn down", expect: "listening")
        run("Esc", expect: "cancelled")
        run("Error: mic access off", expect: "error")
        run("Dismiss", expect: "hidden")
        run("Fn down", expect: "listening")
        run("Release, then Fn again", frames: 1, expect: "done")
        print("frame " + PillRenderCommand.summary(costs))
        // The real panel: built once, never key, non-activating, hidden until a take starts.
        let real = PillPanel(theme: theme)
        let panelOK = !real.panel.canBecomeKey && !real.panel.canBecomeMain && real.panel.styleMask.contains(.nonactivatingPanel)
            && !real.panel.isVisible && real.panel.ignoresMouseEvents
        print("real panel: \(panelOK ? "ok" : "WRONG FLAGS")")
        ok = ok && panelOK
        print(ok ? "self-test passed" : "self-test FAILED")
        return ok
    }
}

/// The lab window: Space held = Fn held. Local key events only.
private final class LabWindow: NSWindow {
    var onSpace: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { if !event.isARepeat { onSpace?(true) }; return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { onSpace?(false); return }
        super.keyUp(with: event)
    }
}

/// Stage: a backdrop with the pill on top. Reports clicks and hover in pill coordinates.
final class LabStageView: NSView {
    var onClick: ((CGPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Whether a point (pill coordinates) is over the pill.
    var isOverPill: ((CGPoint) -> Bool)?
    var pillOrigin: CGPoint = .zero
    private let backdrop = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        backdrop.frame = bounds
        layer?.addSublayer(backdrop)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    func setBackdrop(_ image: CGImage) {
        backdrop.contents = image
    }

    private var inside = false
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let now = isOverPill?(CGPoint(x: p.x - pillOrigin.x, y: p.y - pillOrigin.y)) ?? false
        if now != inside { inside = now; onHover?(now) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onClick?(CGPoint(x: p.x - pillOrigin.x, y: p.y - pillOrigin.y))
    }
}
